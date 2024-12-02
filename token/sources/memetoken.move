module dogetokenmeme::tokenV3 {
    use std::string;
    use std::signer;
    use std::option;
    use aptos_framework::coin::{Self, MintCapability, BurnCapability, FreezeCapability};

    /// Error codes
    const ENO_ADMIN_PRIVILEGE: u64 = 1;
    const EZERO_MINT_AMOUNT: u64 = 2;

    struct DogeTokenMeme {}

    struct Capabilities has key {
        mint_cap: coin::MintCapability<DogeTokenMeme>,
        burn_cap: coin::BurnCapability<DogeTokenMeme>,
        freeze_cap: coin::FreezeCapability<DogeTokenMeme>,
    }

    public entry fun initialize(admin: &signer) acquires Capabilities {
        let admin_addr = signer::address_of(admin);
        
        // Initialize the coin
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<DogeTokenMeme>(
            admin,
            string::utf8(b"Meme Token"),     // Name
            string::utf8(b"DOGE"),           // Symbol
            6,                               // Decimals
            true                             // Monitor supply
        );

        // Store the capabilities
        move_to(admin, Capabilities {
            mint_cap,
            burn_cap,
            freeze_cap,
        });

        // Register the admin account to receive the tokens
        if (!coin::is_account_registered<DogeTokenMeme>(admin_addr)) {
            coin::register<DogeTokenMeme>(admin);
        };

        // Mint initial supply to admin (e.g., 1 billion tokens)
        // 1,000,000,000 tokens with 6 decimals = 1,000,000,000,000,000
        let initial_supply = 1000000000000000;
        mint(admin_addr, initial_supply);
    }

    public entry fun mint(
        account_addr: address,
        amount: u64
    ) acquires Capabilities {
        assert!(amount > 0, EZERO_MINT_AMOUNT);
        
        let caps = borrow_global<Capabilities>(@dogetokenmeme);
        let coins = coin::mint(amount, &caps.mint_cap);
        coin::deposit(account_addr, coins);
    }

    public entry fun burn(
        account: &signer,
        amount: u64
    ) acquires Capabilities {
        let caps = borrow_global<Capabilities>(@dogetokenmeme);
        let coins = coin::withdraw<DogeTokenMeme>(account, amount);
        coin::burn(coins, &caps.burn_cap);
    }

    public entry fun register(account: &signer) {
        if (!coin::is_account_registered<DogeTokenMeme>(signer::address_of(account))) {
            coin::register<DogeTokenMeme>(account);
        };
    }

    public entry fun transfer(
        from: &signer,
        to: address,
        amount: u64
    ) {
        // First ensure the recipient account is registered to receive the token
        if (!coin::is_account_registered<DogeTokenMeme>(to)) {
            // If not registered, the transfer will fail
            return
        };
        
        // Transfer tokens using the coin module's transfer function
        coin::transfer<DogeTokenMeme>(from, to, amount);
    }

    #[view]
    public fun balance_of(owner: address): u64 {
        if (!coin::is_account_registered<DogeTokenMeme>(owner)) {
            return 0
        };
        coin::balance<DogeTokenMeme>(owner)
    }

    #[view]
    public fun get_supply(): u64 {
        let supply_opt = coin::supply<DogeTokenMeme>();
        if (option::is_some(&supply_opt)) {
            ((option::extract(&mut supply_opt) as u128) as u64)
        } else {
            0
        }
    }
}