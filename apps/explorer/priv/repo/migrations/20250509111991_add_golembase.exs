defmodule Explorer.Repo.Migrations.AddGolemBase do
  use Ecto.Migration

  def change do
    execute("ALTER TYPE transaction_actions_protocol ADD VALUE 'golembase'")
    execute("ALTER TYPE transaction_actions_type ADD VALUE 'golembase_entity_created'")
  end
end
