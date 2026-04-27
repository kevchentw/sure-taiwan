module SettingsHelper
  SETTINGS_ORDER = [
    # General section
    { label_key: "accounts_label", path: :accounts_path },
    { label_key: "bank_sync_label", path: :settings_bank_sync_path },
    { label_key: "preferences_label", path: :settings_preferences_path },
    { label_key: "appearance_label", path: :settings_appearance_path },
    { label_key: "profile_label", path: :settings_profile_path },
    { label_key: "security_label", path: :settings_security_path },
    { label_key: "payment_label", path: :settings_payment_path, condition: :not_self_hosted? },
    # Transactions section
    { label_key: "categories_label", path: :categories_path },
    { label_key: "tags_label", path: :tags_path },
    { label_key: "rules_label", path: :rules_path },
    { label_key: "merchants_label", path: :family_merchants_path },
    { label_key: "recurring_transactions_label", path: :recurring_transactions_path },
    # Advanced section
    { label_key: "ai_prompts_label", path: :settings_ai_prompts_path, condition: :admin_user? },
    { label_key: "llm_usage_label", path: :settings_llm_usage_path, condition: :admin_user? },
    { label_key: "api_keys_label", path: :settings_api_key_path, condition: :admin_user? },
    { label_key: "self_hosting_label", path: :settings_hosting_path, condition: :self_hosted_and_admin? },
    { label_key: "providers_label", path: :settings_providers_path, condition: :admin_user? },
    { label_key: "imports_label", path: :imports_path, condition: :admin_user? },
    { label_key: "exports_label", path: :family_exports_path, condition: :admin_user? },
    # More section
    { label_key: "guides_label", path: :settings_guides_path },
    { label_key: "whats_new_label", path: :changelog_path },
    { label_key: "feedback_label", path: :feedback_path }
  ]

  def adjacent_setting(current_path, offset)
    visible_settings = SETTINGS_ORDER.select { |setting| setting[:condition].nil? || send(setting[:condition]) }
    current_index = visible_settings.index { |setting| send(setting[:path]) == current_path }
    return nil unless current_index

    adjacent_index = current_index + offset
    return nil if adjacent_index < 0 || adjacent_index >= visible_settings.size

    adjacent = visible_settings[adjacent_index]

    render partial: "settings/settings_nav_link_large", locals: {
      path: send(adjacent[:path]),
      direction: offset > 0 ? "next" : "previous",
      title: t("settings.settings_nav.#{adjacent[:label_key]}")
    }
  end

  def settings_section(title:, subtitle: nil, collapsible: false, open: true, auto_open_param: nil, &block)
    content = capture(&block)
    render partial: "settings/section", locals: { title: title, subtitle: subtitle, content: content, collapsible: collapsible, open: open, auto_open_param: auto_open_param }
  end

  def settings_nav_footer
    previous_setting = adjacent_setting(request.path, -1)
    next_setting = adjacent_setting(request.path, 1)

    content_tag :div, class: "hidden md:flex flex-row justify-between gap-4" do
      concat(previous_setting)
      concat(next_setting)
    end
  end

  def settings_nav_footer_mobile
    previous_setting = adjacent_setting(request.path, -1)
    next_setting = adjacent_setting(request.path, 1)

    content_tag :div, class: "md:hidden flex flex-col gap-4 pb-[env(safe-area-inset-bottom)]" do
      concat(previous_setting)
      concat(next_setting)
    end
  end

  private
    def not_self_hosted?
      !self_hosted?
    end

    # Helper used by SETTINGS_ORDER conditions
    def admin_user?
      Current.user&.admin?
    end

    def self_hosted_and_admin?
      self_hosted? && admin_user?
    end
end
