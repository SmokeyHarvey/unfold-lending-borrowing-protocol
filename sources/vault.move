module memepoolbank::vault_V2 {
    use std::signer;
    use std::string::{Self, String};
    use aptos_framework::event;
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use aptos_std::table::{Self, Table};

    friend memepoolbank::lending_V2;

    const INIT_VAULT_SEED: vector<u8> = b"memepoolbank_vault_v1";
    const DOGE_RESERVE_FACTOR: u64 = 500; // 5%
    const DOGE_WITHDRAWAL_LIMIT: u64 = 1000000000; // 1000 DOGE

    /// Error codes
    const ENOT_AUTHORIZED: u64 = 1;
    const EASSET_NOT_SUPPORTED: u64 = 2;
    const EINSUFFICIENT_BALANCE: u64 = 3;
    const EINVALID_AMOUNT: u64 = 4;
    const EVAULT_NOT_INITIALIZED: u64 = 5; 
    const EVAULT_CAP_NOT_FOUND: u64 = 6;
    const EALREADY_INITIALIZED: u64 = 7;

    /// Resource account signer capability
    struct VaultCapability has key {
        signer_cap: SignerCapability,
    }

    struct VaultInfo has key {
        resource_addr: address
    }

    /// Vault configuration for each asset
    struct AssetConfig has store, drop, copy {
        reserve_factor: u64,
        withdrawal_limit: u64,
        is_active: bool,
    }

    /// Vault storage
   struct Vault has key {
        assets: Table<String, AssetConfig>,
        balances: Table<String, u64>,
        withdrawal_events: event::EventHandle<WithdrawEvent>,
        deposit_events: event::EventHandle<DepositEvent>,
    }

    /// Events
    struct WithdrawEvent has drop, store {
        asset: String,
        amount: u64,
        recipient: address,
        timestamp: u64,
    }

    struct DepositEvent has drop, store {
        asset: String,
        amount: u64,
        depositor: address,
        timestamp: u64,
    }

    public entry fun initialize<CoinType>(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @memepoolbank, ENOT_AUTHORIZED);
        assert!(!exists<Vault>(admin_addr), EALREADY_INITIALIZED);
        assert!(!exists<VaultCapability>(admin_addr), EALREADY_INITIALIZED);

        // Create resource account
        let (resource_signer, signer_cap) = account::create_resource_account(admin, INIT_VAULT_SEED);
        let resource_addr = signer::address_of(&resource_signer);

        // Store capability
        move_to(admin, VaultCapability { signer_cap });
        move_to(admin, VaultInfo { resource_addr });

        // Initialize vault with pre-configured DOGE
        let mut_vault = Vault {
            assets: table::new(),
            balances: table::new(),
            withdrawal_events: account::new_event_handle<WithdrawEvent>(admin),
            deposit_events: account::new_event_handle<DepositEvent>(admin)
        };

        // Pre-configure DOGE asset
        let doge_config = AssetConfig {
            reserve_factor: DOGE_RESERVE_FACTOR,
            withdrawal_limit: DOGE_WITHDRAWAL_LIMIT,
            is_active: true,
        };

        table::add(&mut mut_vault.assets, string::utf8(b"DOGE"), doge_config);
        table::add(&mut mut_vault.balances, string::utf8(b"DOGE"), 0);

        move_to(admin, mut_vault);

        // Register CoinType in vault account
        if (!coin::is_account_registered<CoinType>(resource_addr)) {
            coin::register<CoinType>(&resource_signer);
        };
    }

    public fun get_vault_address(admin_addr: address): address acquires VaultInfo {
        let cap = borrow_global<VaultInfo>(admin_addr);
        cap.resource_addr
    }

    public entry fun recover_vault_cap(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @memepoolbank, ENOT_AUTHORIZED);
        assert!(exists<Vault>(admin_addr), EVAULT_NOT_INITIALIZED);
        assert!(!exists<VaultCapability>(admin_addr), EVAULT_CAP_NOT_FOUND);

        // Create new resource account with deterministic seed
        let (_, signer_cap) = account::create_resource_account(admin, b"memepoolbank_vault_v1");
        
        // Store the capability
        move_to(admin, VaultCapability { 
            signer_cap
        });
    }

    public entry fun add_asset<CoinType>(
        admin: &signer,
        asset: String,
        reserve_factor: u64,
        withdrawal_limit: u64
    ) acquires Vault, VaultCapability {
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @memepoolbank, ENOT_AUTHORIZED);

        // Verify vault exists
        assert!(exists<Vault>(admin_addr), EVAULT_NOT_INITIALIZED);
        assert!(exists<VaultCapability>(admin_addr), EVAULT_CAP_NOT_FOUND);

        let vault = borrow_global_mut<Vault>(admin_addr);
        
        let config = AssetConfig {
            reserve_factor,
            withdrawal_limit,
            is_active: true,
        };

        if (!table::contains(&vault.assets, asset)) {
            table::add(&mut vault.assets, asset, config);
            table::add(&mut vault.balances, asset, 0);
        };

        // Get vault signer and register coin
        let cap = borrow_global<VaultCapability>(admin_addr);
        let vault_signer = account::create_signer_with_capability(&cap.signer_cap);
        if (!coin::is_account_registered<CoinType>(signer::address_of(&vault_signer))) {
            coin::register<CoinType>(&vault_signer);
        };
    }

    /// Deposit assets
    public entry fun deposit<CoinType>(
        from: &signer,
        asset: String,
        amount: u64
    ) acquires Vault {
        let vault = borrow_global_mut<Vault>(@memepoolbank);
        assert!(table::contains(&vault.assets, asset), EASSET_NOT_SUPPORTED);
        assert!(amount > 0, EINVALID_AMOUNT);

        // Update balance
        let balance = table::borrow_mut(&mut vault.balances, asset);
        *balance = *balance + amount;

        // Transfer coins
        coin::transfer<CoinType>(from, @memepoolbank, amount);

        // Emit event
        event::emit_event(
            &mut vault.deposit_events,
            DepositEvent {
                asset,
                amount,
                depositor: signer::address_of(from),
                timestamp: timestamp::now_seconds(),
            }
        );
    }

    /// Withdraw assets (friend function for lending module)
    public(friend) entry fun withdraw<CoinType>(
        asset: String,
        amount: u64,
        recipient: address
    ) acquires Vault, VaultCapability {
        let vault = borrow_global_mut<Vault>(@memepoolbank);
        assert!(table::contains(&vault.assets, asset), EASSET_NOT_SUPPORTED);
        
        let balance = table::borrow_mut(&mut vault.balances, asset);
        assert!(*balance >= amount, EINSUFFICIENT_BALANCE);
        *balance = *balance - amount;

        // Get vault signer and transfer
        let cap = borrow_global<VaultCapability>(@memepoolbank);
        let vault_signer = account::create_signer_with_capability(&cap.signer_cap);
        
        if (!coin::is_account_registered<CoinType>(recipient)) {
            coin::register<CoinType>(&vault_signer);
        };
        coin::transfer<CoinType>(&vault_signer, recipient, amount);

        // Emit event
        event::emit_event(
            &mut vault.withdrawal_events,
            WithdrawEvent {
                asset,
                amount,
                recipient,
                timestamp: timestamp::now_seconds(),
            }
        );
    }

    /// Get asset balance
    public fun get_balance(asset: String): u64 acquires Vault {
        let vault = borrow_global<Vault>(@memepoolbank);
        if (!table::contains(&vault.balances, asset)) {
            return 0
        };
        *table::borrow(&vault.balances, asset)
    }
}