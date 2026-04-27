class AddExternalIdToImportRowsAndImports < ActiveRecord::Migration[7.2]
  def change
    add_column :import_rows, :external_id, :string
    add_column :imports, :external_id_col_label, :string
  end
end
