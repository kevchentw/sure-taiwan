class EpassbookItemsController < ApplicationController
  before_action :set_epassbook_item, only: [ :destroy, :sync, :otp, :verify_otp, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :new, :create, :destroy, :sync, :otp, :verify_otp, :select_existing_account, :link_existing_account, :setup_accounts, :complete_account_setup ]

  def index
    @epassbook_items = Current.family.epassbook_items.active.ordered
    render layout: "settings"
  end

  def new
    @epassbook_item = Current.family.epassbook_items.build
  end

  def create
    @epassbook_item = Current.family.epassbook_items.build(epassbook_item_params)

    unless @epassbook_item.save
      return render :new, status: :unprocessable_entity
    end

    begin
      client = Provider::Epassbook.new(dev_id: @epassbook_item.dev_id)
      result = client.login(user_id: @epassbook_item.tdcc_user_id, password: @epassbook_item.tdcc_password)
      @epassbook_item.save_token!(client.token_id)

      if result["isDiffDevice"] == "Y"
        client.request_email_otp(user_id: @epassbook_item.tdcc_user_id)
        redirect_to otp_epassbook_item_path(@epassbook_item), notice: t(".otp_sent")
      else
        @epassbook_item.sync_later
        redirect_to accounts_path, notice: t(".success"), status: :see_other
      end
    rescue Provider::Epassbook::EpassbookError => e
      @epassbook_item.destroy
      @epassbook_item = Current.family.epassbook_items.build(epassbook_item_params)
      @error_message = e.message
      render :new, status: :unprocessable_entity
    rescue => e
      Rails.logger.error("EpassbookItemsController#create: #{e.class} - #{e.message}")
      @epassbook_item.destroy
      @epassbook_item = Current.family.epassbook_items.build(epassbook_item_params)
      @error_message = t(".errors.unexpected")
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    begin
      @epassbook_item.unlink_all!(dry_run: false)
    rescue => e
      Rails.logger.warn("EpassbookItemsController#destroy unlink failed: #{e.class} - #{e.message}")
    end
    @epassbook_item.destroy_later
    redirect_to accounts_path, notice: t(".success"), status: :see_other
  end

  def sync
    @epassbook_item.sync_later unless @epassbook_item.syncing?
    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def otp
  end

  def verify_otp
    client = @epassbook_item.epassbook_client
    unless client
      return redirect_to accounts_path, alert: t(".errors.no_credentials")
    end

    begin
      client.verify_otp(user_id: @epassbook_item.tdcc_user_id, otp: params[:otp_code].to_s.strip)
      @epassbook_item.save_token!(client.token_id)
      @epassbook_item.sync_later
      redirect_to accounts_path, notice: t(".success"), status: :see_other
    rescue Provider::Epassbook::EpassbookError => e
      @error_message = e.message
      render :otp, status: :unprocessable_entity
    rescue => e
      Rails.logger.error("EpassbookItemsController#verify_otp: #{e.class} - #{e.message}")
      @error_message = t(".errors.unexpected")
      render :otp, status: :unprocessable_entity
    end
  end

  def setup_accounts
    @epassbook_accounts = @epassbook_item.epassbook_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })

    @investment_subtype_options = Investment::SUBTYPES
      .select { |_, v| v[:region] == "tw" || v[:region].nil? }
      .map { |k, v| [ v[:long], k ] }

    @depository_subtype_options = Depository::SUBTYPES.map { |k, v| [ v[:long], k ] }
  end

  def complete_account_setup
    account_types    = params[:account_types] || {}
    account_subtypes = params[:account_subtypes] || {}
    created_accounts = []

    account_types.each do |epassbook_account_id, selected_type|
      next if selected_type.blank? || selected_type == "skip"

      epassbook_account = @epassbook_item.epassbook_accounts.find_by(id: epassbook_account_id)
      next unless epassbook_account
      next if epassbook_account.current_account.present?

      selected_subtype = account_subtypes[epassbook_account_id]
      account = Account.create_from_epassbook_account(epassbook_account, selected_type, selected_subtype)
      epassbook_account.ensure_account_provider!(account)
      created_accounts << account
    rescue => e
      Rails.logger.error("EpassbookItemsController#complete_account_setup account #{epassbook_account_id}: #{e.class} - #{e.message}")
    end

    @epassbook_item.update!(pending_account_setup: false)
    @epassbook_item.sync_later if created_accounts.any?

    redirect_to accounts_path,
      notice: t(".success", count: created_accounts.count),
      status: :see_other
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @available_epassbook_accounts = Current.family.epassbook_items
      .includes(epassbook_accounts: :account_provider)
      .flat_map(&:epassbook_accounts)
      .select { |ea| ea.account_provider.nil? }
      .sort_by(&:display_name)
    render layout: false
  end

  def link_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    epassbook_account = EpassbookAccount.find(params[:epassbook_account_id])

    unless Current.family.epassbook_items.include?(epassbook_account.epassbook_item)
      return redirect_to account_path(@account),
        alert: t(".errors.invalid_epassbook_account"), status: :see_other
    end

    AccountProvider.find_or_initialize_by(provider: epassbook_account).tap do |ap|
      ap.account = @account
      ap.save!
    end

    redirect_to accounts_path, notice: t(".success"), status: :see_other
  end

  private

    def set_epassbook_item
      @epassbook_item = Current.family.epassbook_items.find(params[:id])
    end

    def epassbook_item_params
      params.require(:epassbook_item).permit(:tdcc_user_id, :tdcc_password, :name)
    end
end
