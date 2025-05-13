defmodule Explorer.Repo.Migrations.AddGolemBase do
  use Ecto.Migration

  def change do
    execute("ALTER TYPE transaction_actions_protocol ADD VALUE 'golembase'")
    execute("ALTER TYPE transaction_actions_type ADD VALUE 'golembase_entity_created'")
    execute("ALTER TYPE transaction_actions_type ADD VALUE 'golembase_entity_updated'")
    execute("ALTER TYPE transaction_actions_type ADD VALUE 'golembase_entity_deleted'")
    execute("ALTER TYPE transaction_actions_type ADD VALUE 'golembase_entity_ttl_extended'")
  end
end
