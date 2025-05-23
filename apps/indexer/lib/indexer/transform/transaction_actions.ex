defmodule Indexer.Transform.TransactionActions do
  @moduledoc """
  Helper functions for transforming data for transaction actions.
  """

  require Logger

  import Ecto.Query, only: [from: 2]
  import Explorer.Chain.SmartContract, only: [burn_address_hash_string: 0]
  import Explorer.Helper, only: [decode_data: 2]

  alias Explorer.Chain.Cache.{ChainId, TransactionActionTokensData, TransactionActionUniswapPools}
  alias Explorer.Chain.{Address, Hash, Token, TransactionAction}
  alias Explorer.Repo
  alias Indexer.Helper, as: IndexerHelper

  @mainnet 1
  @goerli 5
  @optimism 10
  @polygon 137
  @base_mainnet 8453
  @base_goerli 84531
  # TODO: Figure out the correct Golem Base chain ID.
  @golembase 1337
  # @gnosis 100

  @uniswap_v3_factory_abi [
    %{
      "inputs" => [
        %{"internalType" => "address", "name" => "", "type" => "address"},
        %{"internalType" => "address", "name" => "", "type" => "address"},
        %{"internalType" => "uint24", "name" => "", "type" => "uint24"}
      ],
      "name" => "getPool",
      "outputs" => [%{"internalType" => "address", "name" => "", "type" => "address"}],
      "stateMutability" => "view",
      "type" => "function"
    }
  ]
  @uniswap_v3_pool_abi [
    %{
      "inputs" => [],
      "name" => "fee",
      "outputs" => [%{"internalType" => "uint24", "name" => "", "type" => "uint24"}],
      "stateMutability" => "view",
      "type" => "function"
    },
    %{
      "inputs" => [],
      "name" => "token0",
      "outputs" => [%{"internalType" => "address", "name" => "", "type" => "address"}],
      "stateMutability" => "view",
      "type" => "function"
    },
    %{
      "inputs" => [],
      "name" => "token1",
      "outputs" => [%{"internalType" => "address", "name" => "", "type" => "address"}],
      "stateMutability" => "view",
      "type" => "function"
    }
  ]
  @erc20_abi [
    %{
      "constant" => true,
      "inputs" => [],
      "name" => "symbol",
      "outputs" => [%{"name" => "", "type" => "string"}],
      "payable" => false,
      "stateMutability" => "view",
      "type" => "function"
    },
    %{
      "constant" => true,
      "inputs" => [],
      "name" => "decimals",
      "outputs" => [%{"name" => "", "type" => "uint8"}],
      "payable" => false,
      "stateMutability" => "view",
      "type" => "function"
    }
  ]

  # 32-byte signature of the event Borrow(address indexed reserve, address user, address indexed onBehalfOf, uint256 amount, uint8 interestRateMode, uint256 borrowRate, uint16 indexed referralCode)
  @aave_v3_borrow_event "0xb3d084820fb1a9decffb176436bd02558d15fac9b0ddfed8c465bc7359d7dce0"

  # 32-byte signature of the event Supply(address indexed reserve, address user, address indexed onBehalfOf, uint256 amount, uint16 indexed referralCode)
  @aave_v3_supply_event "0x2b627736bca15cd5381dcf80b0bf11fd197d01a037c52b927a881a10fb73ba61"

  # 32-byte signature of the event Withdraw(address indexed reserve, address indexed user, address indexed to, uint256 amount)
  @aave_v3_withdraw_event "0x3115d1449a7b732c986cba18244e897a450f61e1bb8d589cd2e69e6c8924f9f7"

  # 32-byte signature of the event Repay(address indexed reserve, address indexed user, address indexed repayer, uint256 amount, bool useATokens)
  @aave_v3_repay_event "0xa534c8dbe71f871f9f3530e97a74601fea17b426cae02e1c5aee42c96c784051"

  # 32-byte signature of the event FlashLoan(address indexed target, address initiator, address indexed asset, uint256 amount, uint8 interestRateMode, uint256 premium, uint16 indexed referralCode)
  @aave_v3_flash_loan_event "0xefefaba5e921573100900a3ad9cf29f222d995fb3b6045797eaea7521bd8d6f0"

  # 32-byte signature of the event ReserveUsedAsCollateralEnabled(address indexed reserve, address indexed user)
  @aave_v3_enable_collateral_event "0x00058a56ea94653cdf4f152d227ace22d4c00ad99e2a43f58cb7d9e3feb295f2"

  # 32-byte signature of the event ReserveUsedAsCollateralDisabled(address indexed reserve, address indexed user)
  @aave_v3_disable_collateral_event "0x44c58d81365b66dd4b1a7f36c25aa97b8c71c361ee4937adc1a00000227db5dd"

  # 32-byte signature of the event LiquidationCall(address indexed collateralAsset, address indexed debtAsset, address indexed user, uint256 debtToCover, uint256 liquidatedCollateralAmount, address liquidator, bool receiveAToken)
  @aave_v3_liquidation_call_event "0xe413a321e8681d831f4dbccbca790d2952b56f977908e45be37335533e005286"

  # 32-byte signature of the event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)
  @uniswap_v3_transfer_nft_event "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

  # 32-byte signature of the event Mint(address sender, address indexed owner, int24 indexed tickLower, int24 indexed tickUpper, uint128 amount, uint256 amount0, uint256 amount1)
  @uniswap_v3_mint_event "0x7a53080ba414158be7ec69b987b5fb7d07dee101fe85488f0853ae16239d0bde"

  # 32-byte signature of the event Burn(address indexed owner, int24 indexed tickLower, int24 indexed tickUpper, uint128 amount, uint256 amount0, uint256 amount1)
  @uniswap_v3_burn_event "0x0c396cd989a39f4459b5fa1aed6a9a8dcdbc45908acfd67e028cd568da98982c"

  # 32-byte signature of the event Collect(address indexed owner, address recipient, int24 indexed tickLower, int24 indexed tickUpper, uint128 amount0, uint128 amount1)
  @uniswap_v3_collect_event "0x70935338e69775456a85ddef226c395fb668b63fa0115f5f20610b388e6ca9c0"

  # 32-byte signature of the event Swap(address indexed sender, address indexed recipient, int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick);
  @uniswap_v3_swap_event "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"

  # 32-byte signature of the event GolemBaseStorageEntityCreated(bytes32 entityKey, uint256 expirationBlock)
  @golembase_entity_created "0xce4b4ad6891d716d0b1fba2b4aeb05ec20edadb01df512263d0dde423736bbb9"

  # 32-byte signature of the event GolemBaseStorageEntityUpdated(bytes32 entityKey, uint256 newExpirationBlock)
  @golembase_entity_updated "0xf371f40aa6932ad9dacbee236e5f3b93d478afe3934b5cfec5ea0d800a41d165"

  # 32-byte signature of the event GolemBaseStorageEntityDeleted(bytes32 entityKey)
  @golembase_entity_deleted "0x0297b0e6eaf1bc2289906a8123b8ff5b19e568a60d002d47df44f8294422af93"

  # 32-byte signature of the event GolemBaseStorageEntityTTLExtended(bytes32 entityKey, uint256 oldExpirationBlock, uint256 newExpirationBlock)
  @golembase_entity_ttl_extended "0x49f78ff301f2020db26cdf781a7e801d1015e0b851fe4117c7740837ed6724e9"

  # max number of token decimals
  @decimals_max 0xFF

  @doc """
  Returns a list of transaction actions given a list of logs.
  """
  def parse(logs, protocols_to_rewrite \\ nil) do
    if Application.get_env(:indexer, Indexer.Fetcher.TransactionAction.Supervisor)[:enabled] do
      actions = []

      chain_id = ChainId.get_id()

      if not is_nil(protocols_to_rewrite) do
        logs
        |> logs_group_by_transactions()
        |> clear_actions(protocols_to_rewrite)
      end

      # create tokens cache if not exists
      TransactionActionTokensData.create_cache_table()

      actions = parse_aave_v3(logs, actions, protocols_to_rewrite, chain_id)
      actions = parse_uniswap_v3(logs, actions, protocols_to_rewrite, chain_id)
      actions = parse_golembase(logs, actions, protocols_to_rewrite, chain_id)

      %{transaction_actions: actions}
    else
      %{transaction_actions: []}
    end
  end

  defp parse_aave_v3(logs, actions, protocols_to_rewrite, chain_id) do
    aave_v3_pool = Application.get_all_env(:indexer)[Indexer.Fetcher.TransactionAction][:aave_v3_pool]

    if not is_nil(aave_v3_pool) and
         (is_nil(protocols_to_rewrite) or Enum.empty?(protocols_to_rewrite) or
            Enum.member?(protocols_to_rewrite, "aave_v3")) do
      logs
      |> aave_filter_logs(String.downcase(aave_v3_pool))
      |> logs_group_by_transactions()
      |> aave(actions, chain_id)
    else
      actions
    end
  end

  defp parse_uniswap_v3(logs, actions, protocols_to_rewrite, chain_id) do
    if Enum.member?([@mainnet, @goerli, @optimism, @polygon, @base_mainnet, @base_goerli], chain_id) and
         (is_nil(protocols_to_rewrite) or Enum.empty?(protocols_to_rewrite) or
            Enum.member?(protocols_to_rewrite, "uniswap_v3")) do
      uniswap_v3_positions_nft =
        String.downcase(
          Application.get_all_env(:indexer)[Indexer.Fetcher.TransactionAction][:uniswap_v3_nft_position_manager]
        )

      logs
      |> uniswap_filter_logs(uniswap_v3_positions_nft)
      |> logs_group_by_transactions()
      |> uniswap(actions, chain_id, uniswap_v3_positions_nft)
    else
      actions
    end
  end

  defp aave_filter_logs(logs, pool_address) do
    logs
    |> Enum.filter(fn log ->
      Enum.member?(
        [
          @aave_v3_borrow_event,
          @aave_v3_supply_event,
          @aave_v3_withdraw_event,
          @aave_v3_repay_event,
          @aave_v3_flash_loan_event,
          @aave_v3_enable_collateral_event,
          @aave_v3_disable_collateral_event,
          @aave_v3_liquidation_call_event
        ],
        sanitize_first_topic(log.first_topic)
      ) && IndexerHelper.address_hash_to_string(log.address_hash, true) == pool_address
    end)
  end

  defp aave(logs_grouped, actions, chain_id) do
    # iterate for each transaction
    Enum.reduce(logs_grouped, actions, fn {_transaction_hash, transaction_logs}, actions_acc ->
      # go through actions
      Enum.reduce(transaction_logs, actions_acc, fn log, acc ->
        acc ++ aave_handle_action(log, chain_id)
      end)
    end)
  end

  # credo:disable-for-next-line /Complexity/
  defp aave_handle_action(log, chain_id) do
    case sanitize_first_topic(log.first_topic) do
      @aave_v3_borrow_event ->
        # this is Borrow event
        aave_handle_borrow_event(log, chain_id)

      @aave_v3_supply_event ->
        # this is Supply event
        aave_handle_supply_event(log, chain_id)

      @aave_v3_withdraw_event ->
        # this is Withdraw event
        aave_handle_withdraw_event(log, chain_id)

      @aave_v3_repay_event ->
        # this is Repay event
        aave_handle_repay_event(log, chain_id)

      @aave_v3_flash_loan_event ->
        # this is FlashLoan event
        aave_handle_flash_loan_event(log, chain_id)

      @aave_v3_enable_collateral_event ->
        # this is ReserveUsedAsCollateralEnabled event
        aave_handle_event("enable_collateral", log, log.second_topic, chain_id)

      @aave_v3_disable_collateral_event ->
        # this is ReserveUsedAsCollateralDisabled event
        aave_handle_event("disable_collateral", log, log.second_topic, chain_id)

      @aave_v3_liquidation_call_event ->
        # this is LiquidationCall event
        aave_handle_liquidation_call_event(log, chain_id)

      _ ->
        []
    end
  end

  defp aave_handle_borrow_event(log, chain_id) do
    [_user, amount, _interest_rate_mode, _borrow_rate] =
      decode_data(log.data, [:address, {:uint, 256}, {:uint, 8}, {:uint, 256}])

    aave_handle_event("borrow", amount, log, log.second_topic, chain_id)
  end

  defp aave_handle_supply_event(log, chain_id) do
    [_user, amount] = decode_data(log.data, [:address, {:uint, 256}])

    aave_handle_event("supply", amount, log, log.second_topic, chain_id)
  end

  defp aave_handle_withdraw_event(log, chain_id) do
    [amount] = decode_data(log.data, [{:uint, 256}])

    aave_handle_event("withdraw", amount, log, log.second_topic, chain_id)
  end

  defp aave_handle_repay_event(log, chain_id) do
    [amount, _use_a_tokens] = decode_data(log.data, [{:uint, 256}, :bool])

    aave_handle_event("repay", amount, log, log.second_topic, chain_id)
  end

  defp aave_handle_flash_loan_event(log, chain_id) do
    [_initiator, amount, _interest_rate_mode, _premium] =
      decode_data(log.data, [:address, {:uint, 256}, {:uint, 8}, {:uint, 256}])

    aave_handle_event("flash_loan", amount, log, log.third_topic, chain_id)
  end

  defp aave_handle_liquidation_call_event(log, chain_id) do
    [debt_amount, collateral_amount, _liquidator, _receive_a_token] =
      decode_data(log.data, [{:uint, 256}, {:uint, 256}, :address, :bool])

    debt_address =
      log.third_topic
      |> IndexerHelper.log_topic_to_string()
      |> truncate_address_hash()

    collateral_address =
      log.second_topic
      |> IndexerHelper.log_topic_to_string()
      |> truncate_address_hash()

    case get_token_data([debt_address, collateral_address]) do
      false ->
        []

      token_data ->
        debt_decimals = token_data[debt_address].decimals
        collateral_decimals = token_data[collateral_address].decimals

        [
          %{
            hash: log.transaction_hash,
            protocol: "aave_v3",
            data: %{
              debt_amount: fractional(Decimal.new(debt_amount), Decimal.new(debt_decimals)),
              debt_symbol: clarify_token_symbol(token_data[debt_address].symbol, chain_id),
              debt_address: Address.checksum(debt_address),
              collateral_amount: fractional(Decimal.new(collateral_amount), Decimal.new(collateral_decimals)),
              collateral_symbol: clarify_token_symbol(token_data[collateral_address].symbol, chain_id),
              collateral_address: Address.checksum(collateral_address),
              block_number: log.block_number
            },
            type: "liquidation_call",
            log_index: log.index
          }
        ]
    end
  end

  defp aave_handle_event(type, amount, log, address_topic, chain_id)
       when type in ["borrow", "supply", "withdraw", "repay", "flash_loan"] do
    address =
      address_topic
      |> IndexerHelper.log_topic_to_string()
      |> truncate_address_hash()

    case get_token_data([address]) do
      false ->
        []

      token_data ->
        decimals = token_data[address].decimals

        [
          %{
            hash: log.transaction_hash,
            protocol: "aave_v3",
            data: %{
              amount: fractional(Decimal.new(amount), Decimal.new(decimals)),
              symbol: clarify_token_symbol(token_data[address].symbol, chain_id),
              address: Address.checksum(address),
              block_number: log.block_number
            },
            type: type,
            log_index: log.index
          }
        ]
    end
  end

  defp aave_handle_event(type, log, address_topic, chain_id) when type in ["enable_collateral", "disable_collateral"] do
    address =
      address_topic
      |> IndexerHelper.log_topic_to_string()
      |> truncate_address_hash()

    case get_token_data([address]) do
      false ->
        []

      token_data ->
        [
          %{
            hash: log.transaction_hash,
            protocol: "aave_v3",
            data: %{
              symbol: clarify_token_symbol(token_data[address].symbol, chain_id),
              address: Address.checksum(address),
              block_number: log.block_number
            },
            type: type,
            log_index: log.index
          }
        ]
    end
  end

  defp golembase(logs_grouped, actions) do
    # iterate for each transaction
    Enum.reduce(logs_grouped, actions, fn {transaction_hash, transaction_logs}, actions_acc ->
      # go through other actions
      Enum.reduce(transaction_logs, actions_acc, fn log, acc ->
        acc ++ golembase_handle_action(log)
      end)
    end)
  end

  defp golembase_handle_action(log) do
    first_topic = sanitize_first_topic(log.first_topic)
    case first_topic do
      @golembase_entity_created ->
        golembase_handle_created_event(log)
      @golembase_entity_updated ->
        golembase_handle_updated_event(log)
      @golembase_entity_deleted ->
        golembase_handle_deleted_event(log)
      @golembase_entity_ttl_extended ->
        golembase_handle_ttl_extended_event(log)
      _ ->
        []
    end
  end

  defp golembase_handle_created_event(log) do
    entity_id = log.second_topic
    [expiration_block] = decode_data(log.data, [{:uint, 256}])

    [
      %{
        hash: log.transaction_hash,
        protocol: "golembase",
        data: %{
          entity_id: entity_id,
          expiration_block: expiration_block
        },
        type: "golembase_entity_created",
        log_index: log.index
      }
    ]
  end

  defp golembase_handle_updated_event(log) do
    entity_id = log.second_topic
    [expiration_block] = decode_data(log.data, [{:uint, 256}])

    [
      %{
        hash: log.transaction_hash,
        protocol: "golembase",
        data: %{
          entity_id: entity_id,
          expiration_block: expiration_block
        },
        type: "golembase_entity_updated",
        log_index: log.index
      }
    ]
  end

  defp golembase_handle_deleted_event(log) do
    entity_id = log.second_topic

    [
      %{
        hash: log.transaction_hash,
        protocol: "golembase",
        data: %{
          entity_id: entity_id,
        },
        type: "golembase_entity_deleted",
        log_index: log.index
      }
    ]
  end

  defp golembase_handle_ttl_extended_event(log) do
    entity_id = log.second_topic
    [old_expiration_block, new_expiration_block] = decode_data(log.data, [{:uint, 256}, {:uint, 256}])

    [
      %{
        hash: log.transaction_hash,
        protocol: "golembase",
        data: %{
          entity_id: entity_id,
          old_expiration_block: old_expiration_block,
          new_expiration_block: new_expiration_block
        },
        type: "golembase_entity_ttl_extended",
        log_index: log.index
      }
    ]
  end

  defp parse_golembase(logs, actions, protocols_to_rewrite, chain_id) do
    Logger.info(["GOLEMBASE Transaction action: ", inspect(actions), " chain_id: ", to_string(chain_id)," expected: ", to_string(@golembase)])
    if chain_id == @golembase and
         (is_nil(protocols_to_rewrite) or Enum.empty?(protocols_to_rewrite) or
            Enum.member?(protocols_to_rewrite, "golembase")) do

      logs
      |> golembase_filter_logs()
      |> logs_group_by_transactions()
      |> golembase(actions)
    else
      actions
    end
  end

  defp golembase_filter_logs(logs) do
    logs
    |> Enum.filter(fn log ->
      first_topic = sanitize_first_topic(log.first_topic)

      result = Enum.member?(
        [
          @golembase_entity_created,
          @golembase_entity_updated,
          @golembase_entity_deleted,
          @golembase_entity_ttl_extended
        ],
        first_topic
      )

      result
    end)
  end

  defp uniswap(logs_grouped, actions, chain_id, uniswap_v3_positions_nft) do
    # create a list of UniswapV3Pool legitimate contracts
    legitimate = uniswap_legitimate_pools(logs_grouped)

    # iterate for each transaction
    Enum.reduce(logs_grouped, actions, fn {transaction_hash, transaction_logs}, actions_acc ->
      # trying to find `mint_nft` actions
      actions_acc =
        uniswap_handle_mint_nft_actions(transaction_hash, transaction_logs, actions_acc, uniswap_v3_positions_nft)

      # go through other actions
      Enum.reduce(transaction_logs, actions_acc, fn log, acc ->
        acc ++ uniswap_handle_action(log, legitimate, chain_id)
      end)
    end)
  end

  defp uniswap_filter_logs(logs, uniswap_v3_positions_nft) do
    logs
    |> Enum.filter(fn log ->
      first_topic = sanitize_first_topic(log.first_topic)

      Enum.member?(
        [
          @uniswap_v3_mint_event,
          @uniswap_v3_burn_event,
          @uniswap_v3_collect_event,
          @uniswap_v3_swap_event
        ],
        first_topic
      ) ||
        (first_topic == @uniswap_v3_transfer_nft_event &&
           IndexerHelper.address_hash_to_string(log.address_hash, true) == uniswap_v3_positions_nft)
    end)
  end

  defp uniswap_handle_action(log, legitimate, chain_id) do
    first_topic = sanitize_first_topic(log.first_topic)

    with false <- first_topic == @uniswap_v3_transfer_nft_event,
         # check UniswapV3Pool contract is legitimate
         pool_address <- IndexerHelper.address_hash_to_string(log.address_hash, true),
         false <- is_nil(legitimate[pool_address]),
         false <- Enum.empty?(legitimate[pool_address]),
         # this is legitimate uniswap pool, so handle this event
         token_address <- legitimate[pool_address],
         token_data <- get_token_data(token_address),
         false <- token_data === false do
      case first_topic do
        @uniswap_v3_mint_event ->
          # this is Mint event
          uniswap_handle_mint_event(log, token_address, token_data, chain_id)

        @uniswap_v3_burn_event ->
          # this is Burn event
          uniswap_handle_burn_event(log, token_address, token_data, chain_id)

        @uniswap_v3_collect_event ->
          # this is Collect event
          uniswap_handle_collect_event(log, token_address, token_data, chain_id)

        @uniswap_v3_swap_event ->
          # this is Swap event
          uniswap_handle_swap_event(log, token_address, token_data, chain_id)

        _ ->
          []
      end
    else
      _ -> []
    end
  end

  defp uniswap_handle_mint_nft_actions(transaction_hash, transaction_logs, actions_acc, uniswap_v3_positions_nft) do
    first_log = Enum.at(transaction_logs, 0)

    local_acc =
      transaction_logs
      |> Enum.reduce(%{}, fn log, acc ->
        if sanitize_first_topic(log.first_topic) == @uniswap_v3_transfer_nft_event do
          # This is Transfer event for NFT
          from =
            log.second_topic
            |> IndexerHelper.log_topic_to_string()
            |> truncate_address_hash()

          # credo:disable-for-next-line
          if from == burn_address_hash_string() do
            to =
              log.third_topic
              |> IndexerHelper.log_topic_to_string()
              |> truncate_address_hash()

            [token_id] =
              log.fourth_topic
              |> IndexerHelper.log_topic_to_string()
              |> decode_data([{:uint, 256}])

            mint_nft_ids = Map.put_new(acc, to, %{ids: [], log_index: log.index})

            Map.put(mint_nft_ids, to, %{
              ids: Enum.reverse([to_string(token_id) | Enum.reverse(mint_nft_ids[to].ids)]),
              log_index: mint_nft_ids[to].log_index
            })
          else
            acc
          end
        else
          acc
        end
      end)
      |> Enum.reduce([], fn {to, %{ids: ids, log_index: log_index}}, acc ->
        action = %{
          hash: transaction_hash,
          protocol: "uniswap_v3",
          data: %{
            name: "Uniswap V3: Positions NFT",
            symbol: "UNI-V3-POS",
            address: uniswap_v3_positions_nft,
            to: Address.checksum(to),
            ids: ids,
            block_number: first_log.block_number
          },
          type: "mint_nft",
          log_index: log_index
        }

        [action | acc]
      end)
      |> Enum.reverse()

    actions_acc ++ local_acc
  end

  defp uniswap_handle_burn_event(log, token_address, token_data, chain_id) do
    [_amount, amount0, amount1] = decode_data(log.data, [{:uint, 128}, {:uint, 256}, {:uint, 256}])

    uniswap_handle_event("burn", amount0, amount1, log, token_address, token_data, chain_id)
  end

  defp uniswap_handle_collect_event(log, token_address, token_data, chain_id) do
    [_recipient, amount0, amount1] = decode_data(log.data, [:address, {:uint, 128}, {:uint, 128}])

    uniswap_handle_event("collect", amount0, amount1, log, token_address, token_data, chain_id)
  end

  defp uniswap_handle_mint_event(log, token_address, token_data, chain_id) do
    [_sender, _amount, amount0, amount1] = decode_data(log.data, [:address, {:uint, 128}, {:uint, 256}, {:uint, 256}])

    uniswap_handle_event("mint", amount0, amount1, log, token_address, token_data, chain_id)
  end

  defp uniswap_handle_swap_event(log, token_address, token_data, chain_id) do
    [amount0, amount1, _sqrt_price_x96, _liquidity, _tick] =
      decode_data(log.data, [{:int, 256}, {:int, 256}, {:uint, 160}, {:uint, 128}, {:int, 24}])

    uniswap_handle_event("swap", amount0, amount1, log, token_address, token_data, chain_id)
  end

  defp uniswap_handle_swap_amounts(log, amount0, amount1, symbol0, symbol1, address0, address1) do
    cond do
      String.first(amount0) === "-" and String.first(amount1) !== "-" ->
        {amount1, symbol1, address1, String.slice(amount0, 1..-1//1), symbol0, address0, false}

      String.first(amount1) === "-" and String.first(amount0) !== "-" ->
        {amount0, symbol0, address0, String.slice(amount1, 1..-1//1), symbol1, address1, false}

      amount1 === "0" and String.first(amount0) !== "-" ->
        {amount0, symbol0, address0, amount1, symbol1, address1, false}

      true ->
        Logger.error(
          "TransactionActions: Invalid Swap event in transaction #{log.transaction_hash}. Log index: #{log.index}. amount0 = #{amount0}, amount1 = #{amount1}"
        )

        {amount0, symbol0, address0, amount1, symbol1, address1, true}
    end
  end

  defp uniswap_handle_event(type, amount0, amount1, log, token_address, token_data, chain_id) do
    address0 = Enum.at(token_address, 0)
    decimals0 = token_data[address0].decimals
    symbol0 = clarify_token_symbol(token_data[address0].symbol, chain_id)
    address1 = Enum.at(token_address, 1)
    decimals1 = token_data[address1].decimals
    symbol1 = clarify_token_symbol(token_data[address1].symbol, chain_id)

    amount0 = fractional(Decimal.new(amount0), Decimal.new(decimals0))
    amount1 = fractional(Decimal.new(amount1), Decimal.new(decimals1))

    {new_amount0, new_symbol0, new_address0, new_amount1, new_symbol1, new_address1, is_error} =
      if type == "swap" do
        uniswap_handle_swap_amounts(log, amount0, amount1, symbol0, symbol1, address0, address1)
      else
        {amount0, symbol0, address0, amount1, symbol1, address1, false}
      end

    if is_error do
      []
    else
      [
        %{
          hash: log.transaction_hash,
          protocol: "uniswap_v3",
          data: %{
            amount0: new_amount0,
            symbol0: new_symbol0,
            address0: Address.checksum(new_address0),
            amount1: new_amount1,
            symbol1: new_symbol1,
            address1: Address.checksum(new_address1),
            block_number: log.block_number
          },
          type: type,
          log_index: log.index
        }
      ]
    end
  end

  defp uniswap_legitimate_pools(logs_grouped) do
    TransactionActionUniswapPools.create_cache_table()

    {pools_to_request, pools_cached} =
      logs_grouped
      |> Enum.reduce(%{}, fn {_transaction_hash, transaction_logs}, addresses_acc ->
        transaction_logs
        |> Enum.filter(fn log ->
          sanitize_first_topic(log.first_topic) != @uniswap_v3_transfer_nft_event
        end)
        |> Enum.reduce(addresses_acc, fn log, acc ->
          pool_address = IndexerHelper.address_hash_to_string(log.address_hash, true)
          Map.put(acc, pool_address, true)
        end)
      end)
      |> Enum.reduce({[], %{}}, fn {pool_address, _}, {to_request, cached} ->
        value_from_cache = TransactionActionUniswapPools.fetch_from_cache(pool_address)

        if is_nil(value_from_cache) do
          {[pool_address | to_request], cached}
        else
          {to_request, Map.put(cached, pool_address, value_from_cache)}
        end
      end)

    req_resp = uniswap_request_tokens_and_fees(pools_to_request)

    case uniswap_request_get_pools(req_resp) do
      {requests_get_pool, responses_get_pool} ->
        requests_get_pool
        |> Enum.zip(responses_get_pool)
        |> Enum.reduce(%{}, fn {request, {_status, response} = _resp}, acc ->
          value = uniswap_pool_is_legitimate(request, response)
          TransactionActionUniswapPools.put_to_cache(request.pool_address, value)
          Map.put(acc, request.pool_address, value)
        end)
        |> Map.merge(pools_cached)

      _ ->
        pools_cached
    end
  end

  defp uniswap_pool_is_legitimate(request, response) do
    response =
      case response do
        [item] -> item
        items -> items
      end

    if request.pool_address == String.downcase(response) do
      [token0, token1, _] = request.args
      [token0, token1]
    else
      []
    end
  end

  defp uniswap_request_get_pools({requests_tokens_and_fees, responses_tokens_and_fees}) do
    uniswap_v3_factory = Application.get_all_env(:indexer)[Indexer.Fetcher.TransactionAction][:uniswap_v3_factory]

    requests_get_pool =
      requests_tokens_and_fees
      |> Enum.zip(responses_tokens_and_fees)
      |> Enum.reduce(%{}, fn {request, {status, response} = _resp}, acc ->
        if status == :ok do
          response = parse_response(response)

          acc = Map.put_new(acc, request.contract_address, %{token0: "", token1: "", fee: ""})
          item = Map.put(acc[request.contract_address], atomized_key(request.method_id), response)
          Map.put(acc, request.contract_address, item)
        else
          acc
        end
      end)
      |> Enum.map(fn {pool_address, pool} ->
        token0 =
          if IndexerHelper.address_correct?(pool.token0),
            do: String.downcase(pool.token0),
            else: burn_address_hash_string()

        token1 =
          if IndexerHelper.address_correct?(pool.token1),
            do: String.downcase(pool.token1),
            else: burn_address_hash_string()

        fee = if pool.fee == "", do: 0, else: pool.fee

        # we will call getPool(token0, token1, fee) public getter
        %{
          pool_address: pool_address,
          contract_address: uniswap_v3_factory,
          method_id: "1698ee82",
          args: [token0, token1, fee]
        }
      end)

    {responses_get_pool, error_messages} = read_contracts(requests_get_pool, @uniswap_v3_factory_abi)

    if not Enum.empty?(error_messages) or Enum.count(requests_get_pool) != Enum.count(responses_get_pool) do
      Logger.error(
        "TransactionActions: Cannot read Uniswap V3 Factory contract getPool public getter. Error messages: #{Enum.join(error_messages, ", ")}. Requests: #{inspect(requests_get_pool)}"
      )

      false
    else
      {requests_get_pool, responses_get_pool}
    end
  end

  defp uniswap_request_tokens_and_fees(pools) do
    requests =
      pools
      |> Enum.map(fn pool_address ->
        # we will call token0(), token1(), fee() public getters
        Enum.map(["0dfe1681", "d21220a7", "ddca3f43"], fn method_id ->
          %{
            contract_address: pool_address,
            method_id: method_id,
            args: []
          }
        end)
      end)
      |> List.flatten()

    {responses, error_messages} = read_contracts(requests, @uniswap_v3_pool_abi)

    if not Enum.empty?(error_messages) do
      incorrect_pools = uniswap_get_incorrect_pools(requests, responses)

      Logger.warning(
        "TransactionActions: Cannot read Uniswap V3 Pool contract public getters for some pools: token0(), token1(), fee(). Error messages: #{Enum.join(error_messages, ", ")}. Incorrect pools: #{Enum.join(incorrect_pools, ", ")} - they will be marked as not legitimate."
      )
    end

    {requests, responses}
  end

  defp uniswap_get_incorrect_pools(requests, responses) do
    responses
    |> Enum.with_index()
    |> Enum.reduce([], fn {{status, _}, i}, acc ->
      if status == :error do
        pool_address = Enum.at(requests, i)[:contract_address]
        TransactionActionUniswapPools.put_to_cache(pool_address, [])
        [pool_address | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp atomized_key("token0"), do: :token0
  defp atomized_key("token1"), do: :token1
  defp atomized_key("fee"), do: :fee
  defp atomized_key("getPool"), do: :getPool
  defp atomized_key("symbol"), do: :symbol
  defp atomized_key("decimals"), do: :decimals
  defp atomized_key("0dfe1681"), do: :token0
  defp atomized_key("d21220a7"), do: :token1
  defp atomized_key("ddca3f43"), do: :fee
  defp atomized_key("1698ee82"), do: :getPool
  defp atomized_key("95d89b41"), do: :symbol
  defp atomized_key("313ce567"), do: :decimals

  defp clarify_token_symbol(symbol, chain_id) do
    if symbol == "WETH" && Enum.member?([@mainnet, @goerli, @optimism], chain_id) do
      "Ether"
    else
      symbol
    end
  end

  defp clear_actions(logs_grouped, protocols_to_clear) do
    logs_grouped
    |> Enum.each(fn {transaction_hash, _} ->
      query =
        if Enum.empty?(protocols_to_clear) do
          from(ta in TransactionAction, where: ta.hash == ^transaction_hash)
        else
          from(ta in TransactionAction, where: ta.hash == ^transaction_hash and ta.protocol in ^protocols_to_clear)
        end

      Repo.delete_all(query)
    end)
  end

  defp fractional(%Decimal{} = amount, %Decimal{} = decimals) do
    amount.sign
    |> Decimal.new(amount.coef, amount.exp - Decimal.to_integer(decimals))
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  defp get_token_data(token_addresses) do
    # first, we're trying to read token data from the cache.
    # if the cache is empty, we read that from DB.
    # if tokens are not in the cache, nor in the DB, read them through RPC.
    token_data =
      token_addresses
      |> get_token_data_from_cache()
      |> get_token_data_from_db()
      |> get_token_data_from_rpc()

    if Enum.any?(token_data, fn {_, token} ->
         Map.get(token, :symbol, "") == "" or Map.get(token, :decimals) > @decimals_max
       end) do
      false
    else
      token_data
    end
  end

  defp get_token_data_from_cache(token_addresses) do
    token_addresses
    |> Enum.reduce(%{}, fn address, acc ->
      Map.put(
        acc,
        address,
        TransactionActionTokensData.fetch_from_cache(address)
      )
    end)
  end

  defp get_token_data_from_db(token_data_from_cache) do
    # a list of token addresses which we should select from the database
    select_tokens_from_db =
      token_data_from_cache
      |> Enum.reduce([], fn {address, data}, acc ->
        if is_nil(data.symbol) or is_nil(data.decimals) do
          [address | acc]
        else
          acc
        end
      end)
      |> Enum.reverse()

    if Enum.empty?(select_tokens_from_db) do
      # we don't need to read data from db, so will use the cache
      token_data_from_cache
    else
      # try to read token symbols and decimals from the database and then save to the cache
      query =
        from(
          t in Token,
          where: t.contract_address_hash in ^select_tokens_from_db,
          select: {t.symbol, t.decimals, t.contract_address_hash}
        )

      query
      |> Repo.all()
      |> Enum.reduce(token_data_from_cache, fn {symbol, decimals, contract_address_hash}, token_data_acc ->
        contract_address_hash = String.downcase(Hash.to_string(contract_address_hash))

        symbol = parse_symbol(symbol, contract_address_hash, token_data_acc)

        decimals = parse_decimals(decimals, contract_address_hash, token_data_acc)

        new_data = %{symbol: symbol, decimals: decimals}

        put_to_cache(contract_address_hash, new_data)

        Map.put(token_data_acc, contract_address_hash, new_data)
      end)
    end
  end

  defp parse_symbol(symbol, contract_address_hash, token_data_acc) do
    if is_nil(symbol) or symbol == "" do
      # if db field is empty, take it from the cache
      token_data_acc[contract_address_hash].symbol
    else
      symbol
    end
  end

  defp parse_decimals(decimals, contract_address_hash, token_data_acc) do
    if is_nil(decimals) do
      # if db field is empty, take it from the cache
      token_data_acc[contract_address_hash].decimals
    else
      decimals
    end
  end

  defp put_to_cache(contract_address_hash, new_data) do
    if Map.get(new_data, :decimals, 0) <= @decimals_max do
      TransactionActionTokensData.put_to_cache(contract_address_hash, new_data)
    end
  end

  defp get_token_data_from_rpc(token_data) do
    token_addresses =
      token_data
      |> Enum.reduce([], fn {address, data}, acc ->
        if is_nil(data.symbol) or data.symbol == "" or is_nil(data.decimals) do
          [address | acc]
        else
          acc
        end
      end)
      |> Enum.reverse()

    {requests, responses} = get_token_data_request_symbol_decimals(token_addresses)

    requests
    |> Enum.zip(responses)
    |> Enum.reduce(token_data, fn {request, {status, response} = _resp}, token_data_acc ->
      if status == :ok do
        response = parse_response(response)

        data = token_data_acc[request.contract_address]

        new_data = get_new_data(data, request, response)

        put_to_cache(request.contract_address, new_data)

        Map.put(token_data_acc, request.contract_address, new_data)
      else
        token_data_acc
      end
    end)
  end

  defp parse_response(response) do
    case response do
      [item] -> item
      items -> items
    end
  end

  defp get_new_data(data, request, response) do
    if atomized_key(request.method_id) == :symbol do
      %{data | symbol: response}
    else
      %{data | decimals: response}
    end
  end

  defp get_token_data_request_symbol_decimals(token_addresses) do
    requests =
      token_addresses
      |> Enum.map(fn address ->
        # we will call symbol() and decimals() public getters
        Enum.map(["95d89b41", "313ce567"], fn method_id ->
          %{
            contract_address: address,
            method_id: method_id,
            args: []
          }
        end)
      end)
      |> List.flatten()

    {responses, error_messages} = read_contracts(requests, @erc20_abi)

    if not Enum.empty?(error_messages) or Enum.count(requests) != Enum.count(responses) do
      Logger.warning(
        "TransactionActions: Cannot read symbol and decimals of an ERC-20 token contract. Error messages: #{Enum.join(error_messages, ", ")}. Addresses: #{Enum.join(token_addresses, ", ")}"
      )
    end

    {requests, responses}
  end

  defp logs_group_by_transactions(logs) do
    logs
    |> Enum.group_by(& &1.transaction_hash)
  end

  defp read_contracts(requests, abi) do
    max_retries = Application.get_env(:explorer, :token_functions_reader_max_retries)
    json_rpc_named_arguments = Application.get_env(:explorer, :json_rpc_named_arguments)

    IndexerHelper.read_contracts_with_retries(requests, abi, json_rpc_named_arguments, max_retries)
  end

  defp sanitize_first_topic(first_topic) do
    if is_nil(first_topic), do: "", else: String.downcase(IndexerHelper.log_topic_to_string(first_topic))
  end

  defp truncate_address_hash(nil), do: burn_address_hash_string()

  defp truncate_address_hash("0x000000000000000000000000" <> truncated_hash) do
    "0x#{truncated_hash}"
  end
end
