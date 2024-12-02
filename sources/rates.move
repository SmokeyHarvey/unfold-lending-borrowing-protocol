module memepoolbank::rates_V2 {
    use std::signer;
    use aptos_framework::event;
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use std::string::String;
    use aptos_std::table::{Self, Table};

    friend memepoolbank::lending_V2;

    /// Error codes
    const ENOT_AUTHORIZED: u64 = 1;
    const EINVALID_RATE: u64 = 2;

    /// Constants
    const SECONDS_PER_YEAR: u64 = 31536000; // 365 days
    const OPTIMAL_UTILIZATION: u64 = 8000;   // 80% in basis points
    const BASIS_POINTS: u64 = 10000;

    /// Interest rate model
    struct RateModel has store, drop, copy {
        base_rate: u64,
        slope1: u64,
        slope2: u64,
        last_update: u64,
        current_rate: u64,
    }

    /// Rate storage
    struct RateStore has key {
        models: Table<String, RateModel>,
        rate_update_events: event::EventHandle<RateUpdateEvent>,
    }

    /// Events
    struct RateUpdateEvent has drop, store {
        asset: String,
        old_rate: u64,
        new_rate: u64,
        utilization: u64,
        timestamp: u64,
    }

    public fun initialize(admin: &signer) {
        assert!(signer::address_of(admin) == @memepoolbank, ENOT_AUTHORIZED);

        if (!exists<RateStore>(@memepoolbank)) {
            move_to(admin, RateStore {
                models: table::new(),
                rate_update_events: account::new_event_handle<RateUpdateEvent>(admin),
            });
        };
    }

    public fun update_rate(
        asset: String,
        total_borrows: u64,
        total_supply: u64
    ): u64 acquires RateStore {
        let store = borrow_global_mut<RateStore>(@memepoolbank);
        assert!(table::contains(&store.models, asset), EINVALID_RATE);

        let model = table::borrow_mut(&mut store.models, asset);
        let current_time = timestamp::now_seconds();
        let time_elapsed = current_time - model.last_update;

        if (time_elapsed > 0) {
            let utilization = if (total_supply == 0) {
                0
            } else {
                (total_borrows * BASIS_POINTS) / total_supply
            };

            let new_rate = calculate_rate(
                utilization,
                model.base_rate,
                model.slope1,
                model.slope2
            );

            let old_rate = model.current_rate;
            model.current_rate = new_rate;
            model.last_update = current_time;

            event::emit_event(
                &mut store.rate_update_events,
                RateUpdateEvent {
                    asset,
                    old_rate,
                    new_rate,
                    utilization,
                    timestamp: current_time,
                }
            );

            new_rate
        } else {
            model.current_rate
        }
    }

    fun calculate_rate(
        utilization: u64,
        base_rate: u64,
        slope1: u64,
        slope2: u64
    ): u64 {
        if (utilization <= OPTIMAL_UTILIZATION) {
            base_rate + (utilization * slope1) / BASIS_POINTS
        } else {
            let base = base_rate + (OPTIMAL_UTILIZATION * slope1) / BASIS_POINTS;
            let excess = utilization - OPTIMAL_UTILIZATION;
            base + (excess * slope2) / BASIS_POINTS
        }
    }

    public fun get_current_rate(asset: String): u64 acquires RateStore {
        let store = borrow_global<RateStore>(@memepoolbank);
        assert!(table::contains(&store.models, asset), EINVALID_RATE);
        table::borrow(&store.models, asset).current_rate
    }
}