module fox_game::barn {
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{Self, TxContext, sender};
    use sui::transfer;
    use sui::table::{Self, Table};
    use sui::object_table::{Self, ObjectTable};
    use sui::event::emit;

    use std::vector as vec;
    use std::hash::sha3_256 as hash;

    use fox_game::token_helper::{Self, FoxOrChicken};
    use fox_game::random;
    #[test_only]
    use fox_game::token_helper::FoCRegistry;

    friend fox_game::fox;

    // maximum alpha score for a Wolf
    const MAX_ALPHA: u8 = 8;
    // sheep earn 10 $EGG per day
    const DAILY_WOOL_RATE: u64 = 10 * 100000000;
    // chicken must have 2 days worth of $EGG to unstake or else it's too cold
    const MINIMUM_TO_EXIT: u64 = 2 * 86400;
    // TEST
    // const MINIMUM_TO_EXIT: u64 = 600;
    const ONE_DAY_IN_SECOND: u64 = 86400;
    // wolves take a 20% tax on all $EGG claimed
    const EGG_CLAIM_TAX_PERCENTAGE: u64 = 20;
    // there will only ever be (roughly) 1.4 million $EGG earned through staking
    const MAXIMUM_GLOBAL_EGG: u64 = 1400000 * 100000000;

    //
    // Errors
    //
    const EALPHA_NOT_STAKED: u64 = 1;
    const ENOT_IN_PACK_OR_BARN: u64 = 2;
    const EINVALID_CALLER: u64 = 3;
    /// For when someone tries to unstake without ownership.
    const EINVALID_OWNER: u64 = 4;
    const ESTILL_COLD: u64 = 25;

    struct BarnRegistry has key, store {
        id: UID,
        // amount of $WOOL earned so far
        total_egg_earned: u64,
        // number of Sheep staked in the Barn
        total_chicken_staked: u64,
        // the last time $WOOL was claimed
        last_claim_timestamp: u64,
        // total alpha scores staked
        total_alpha_staked: u64,
        // any rewards distributed when no wolves are staked
        unaccounted_rewards: u64,
        // amount of $Egg due for each alpha point staked
        egg_per_alpha: u64,
    }

    // struct to store a stake's token, owner, and earning values
    struct Stake has key, store {
        id: UID,
        item: FoxOrChicken,
        value: u64,
        owner: address,
    }

    struct Barn has key, store {
        id: UID,
        stake: Table<ID, ID>,
        items: ObjectTable<ID, Stake>
    }

    struct Pack has key, store {
        id: UID,
        items: Table<u8, vector<Stake>>,
        pack_indices: Table<ID, u64>,
    }

    struct FoCStore<phantom T: key> has key {
        id: UID
    }

    // Events
    struct BarnRegistryCreated has copy, drop { id: ID }

    struct PackCreated has copy, drop { id: ID }

    struct BarnCreated has copy, drop { id: ID }

    struct FoCStaked has copy, drop {
        owner: address,
        id: ID,
        value: u64,
    }

    struct FoCClaimed has copy, drop {
        id: ID,
        earned: u64,
        unstake: bool,
    }

    public fun init_barn_registry(ctx: &mut TxContext): BarnRegistry {
        let id = object::new(ctx);
        emit(BarnRegistryCreated { id: object::uid_to_inner(&id) });
        BarnRegistry {
            id,
            total_egg_earned: 0,
            total_chicken_staked: 0,
            last_claim_timestamp: 0,
            total_alpha_staked: 0,
            unaccounted_rewards: 0,
            egg_per_alpha: 0,
        }
    }

    public fun init_pack(ctx: &mut TxContext): Pack {
        let id = object::new(ctx);
        emit(PackCreated { id: object::uid_to_inner(&id) });
        Pack {
            id,
            items: table::new(ctx),
            pack_indices: table::new(ctx)
        }
    }

    public fun init_barn(ctx: &mut TxContext): Barn {
        let id = object::new(ctx);
        emit(BarnCreated { id: object::uid_to_inner(&id) });
        Barn {
            id,
            stake: table::new(ctx),
            items: object_table::new(ctx)
        }
    }

    public fun stake_many_to_barn_and_pack(
        barn_registry: &mut BarnRegistry,
        barn: &mut Barn,
        pack: &mut Pack,
        tokens: vector<FoxOrChicken>,
        ctx: &mut TxContext,
    ) {
        let i = vec::length<FoxOrChicken>(&tokens);
        while (i > 0) {
            let token = vec::pop_back(&mut tokens);
            if (token_helper::is_chicken(object::id(&token))) {
                update_earnings(barn_registry, ctx);
                stake_chicken_to_barn(barn_registry, barn, token, ctx);
            } else {
                stake_fox_to_pack(barn_registry, pack, token, ctx);
            };
            i = i - 1;
        };
        vec::destroy_empty(tokens)
    }

    public fun claim_many_from_barn_and_pack(
        barn_registry: &mut BarnRegistry,
        barn: &mut Barn,
        pack: &mut Pack,
        tokens: vector<ID>,
        unstake: bool,
        ctx: &mut TxContext,
    ) {
        update_earnings(barn_registry, ctx);
        let i = vec::length<ID>(&tokens);
        // FIXME: with owed
        let owed: u64 = 0;
        while (i > 0) {
            let token_id = vec::pop_back(&mut tokens);
            if (token_helper::is_chicken(token_id)) {
                owed = owed + claim_chicken_from_barn(barn_registry, barn, token_id, unstake, ctx);
            } else {
                owed = owed + claim_fox_from_pack(pack, token_id, unstake, ctx);
            };
            i = i - 1;
        };
        if (owed == 0) { return };
        vec::destroy_empty(tokens)
    }

    fun stake_chicken_to_barn(barn_reg: &mut BarnRegistry, barn: &mut Barn, item: FoxOrChicken, ctx: &mut TxContext) {
        barn_reg.total_chicken_staked = barn_reg.total_chicken_staked + 1;
        add_chicken_to_barn(barn, item, ctx)
    }

    fun stake_fox_to_pack(barn_reg: &mut BarnRegistry, pack: &mut Pack, item: FoxOrChicken, ctx: &mut TxContext) {
        let alpha = token_helper::alpha_for_fox();
        barn_reg.total_alpha_staked = barn_reg.total_alpha_staked + (alpha as u64);
        add_fox_to_pack(pack, item, ctx)
    }

    fun claim_chicken_from_barn(
        barn_registry: &mut BarnRegistry,
        barn: &mut Barn,
        foc_id: ID,
        unstake: bool,
        ctx: &mut TxContext
    ): u64 {
        assert!(table::contains(&barn.stake, foc_id), ENOT_IN_PACK_OR_BARN);
        let stake_time = get_chicken_stake_value(barn, foc_id);
        let timenow = timestamp_now(ctx);
        assert!(!(unstake && timenow - stake_time < MINIMUM_TO_EXIT), ESTILL_COLD);
        let owed: u64;
        if (barn_registry.total_egg_earned < MAXIMUM_GLOBAL_EGG) {
            owed = (timenow - stake_time) * DAILY_WOOL_RATE / ONE_DAY_IN_SECOND;
        } else if (stake_time > barn_registry.last_claim_timestamp) {
            owed = 0; // $WOOL production stopped already
        } else {
            // stop earning additional $WOOL if it's all been earned
            owed = (barn_registry.last_claim_timestamp - stake_time) * DAILY_WOOL_RATE / ONE_DAY_IN_SECOND;
        };
        if (unstake) {
            let id = object::new(ctx);
            if (random::rand_u64_range_with_seed(hash(object::uid_to_bytes(&id)), 0, 2) == 0) {
                // 50% chance of all $EGG stolen
                pay_wolf_tax(barn_registry, owed);
                owed = 0;
            };
            object::delete(id);
            barn_registry.total_chicken_staked = barn_registry.total_chicken_staked - 1;
            let item = remove_chicken_from_barn(barn, foc_id, ctx);
            transfer::transfer(item, sender(ctx));
        } else {
            pay_wolf_tax(barn_registry, owed * EGG_CLAIM_TAX_PERCENTAGE / 100); // percentage tax to staked wolves
            owed = owed * (100 - EGG_CLAIM_TAX_PERCENTAGE) / 100; // remainder goes to Sheep owner
            // reset stake
            set_chicken_stake_value(barn, foc_id, timenow);
        };
        emit(FoCClaimed { id: foc_id, earned: owed, unstake });
        owed
    }

    fun claim_fox_from_pack(pack: &mut Pack, foc_id: ID, unstake: bool, ctx: &mut TxContext): u64 {
        let item = remove_fox_from_pack(pack, foc_id, ctx);
        emit(FoCClaimed { id: foc_id, earned: 0, unstake });
        transfer::transfer(item, sender(ctx));
        0
    }

    fun add_chicken_to_barn(barn: &mut Barn, item: FoxOrChicken, ctx: &mut TxContext) {
        let foc_id = object::id(&item);
        let value = timestamp_now(ctx);
        let stake = Stake {
            id: object::new(ctx),
            item,
            value,
            owner: sender(ctx),
        };
        table::add(&mut barn.stake, foc_id, object::id(&stake));
        emit(FoCStaked { id: foc_id, owner: sender(ctx), value });
        object_table::add(&mut barn.items, object::id(&stake), stake);
    }

    fun add_fox_to_pack(pack: &mut Pack, foc: FoxOrChicken, ctx: &mut TxContext) {
        let foc_id = object::id(&foc);
        let value = timestamp_now(ctx);
        let stake = Stake {
            id: object::new(ctx),
            item: foc,
            value,
            owner: sender(ctx),
        };
        let alpha = token_helper::alpha_for_fox();
        if (!table::contains(&mut pack.items, alpha)) {
            table::add(&mut pack.items, alpha, vec::empty());
        };
        let pack_items = table::borrow_mut(&mut pack.items, alpha);
        vec::push_back(pack_items, stake);

        // Store the location of the wolf in the Pack
        let token_index = vec::length(pack_items) - 1;
        table::add(&mut pack.pack_indices, foc_id, token_index);
        emit(FoCStaked { id: foc_id, owner: sender(ctx), value });
    }

    fun remove_chicken_from_barn(barn: &mut Barn, foc_id: ID, ctx: &mut TxContext): FoxOrChicken {
        let stake_id = table::remove(&mut barn.stake, foc_id);
        let Stake { id, item, value: _, owner } = object_table::remove(&mut barn.items, stake_id);
        assert!(tx_context::sender(ctx) == owner, EINVALID_OWNER);
        object::delete(id);
        item
    }

    fun remove_fox_from_pack(pack: &mut Pack, foc_id: ID, ctx: &mut TxContext): FoxOrChicken {
        // TODO get alpha from foc_id
        let alpha = token_helper::alpha_for_fox();
        assert!(table::contains(&pack.items, alpha), ENOT_IN_PACK_OR_BARN);
        let pack_items = table::borrow_mut(&mut pack.items, alpha);
        // get the index
        assert!(table::contains(&pack.pack_indices, foc_id), ENOT_IN_PACK_OR_BARN);
        let stake_index = table::remove(&mut pack.pack_indices, foc_id);

        let last_stake_index = vec::length(pack_items) - 1;
        if (stake_index != last_stake_index) {
            let last_stake = vec::borrow(pack_items, last_stake_index);
            // update index for swapped token
            let last_foc_id = object::id(&last_stake.item);
            table::remove(&mut pack.pack_indices, last_foc_id);
            table::add(&mut pack.pack_indices, last_foc_id, stake_index);
            // swap last token to current token location and then pop
            vec::swap(pack_items, stake_index, last_stake_index);
        };

        let Stake { id, item, value: _, owner } = vec::pop_back(pack_items);
        assert!(tx_context::sender(ctx) == owner, EINVALID_OWNER);
        object::delete(id);
        item
    }

    fun get_chicken_stake_value(barn: &mut Barn, foc_id: ID): u64 {
        let stake_id = *table::borrow(&mut barn.stake, foc_id);
        let stake = object_table::borrow(&mut barn.items, stake_id);
        stake.value
    }

    fun set_chicken_stake_value(barn: &mut Barn, foc_id: ID, new_value: u64) {
        let stake_id = *table::borrow(&mut barn.stake, foc_id);
        let stake = object_table::borrow_mut(&mut barn.items, stake_id);
        stake.value = new_value;
    }

    // chooses a random Wolf thief when a newly minted token is stolen
    public fun random_wolf_owner(pack: &mut Pack, seed: vector<u8>): address {
        let total_alpha_staked = 10;
        if (total_alpha_staked == 0) {
            return @0x0
        };
        let bucket = random::rand_u64_range_with_seed(seed, 0, total_alpha_staked);
        let cumulative: u64 = 0;
        // loop through each bucket of Wolves with the same alpha score
        let i = MAX_ALPHA - 3;
        while (i <= MAX_ALPHA) {
            let wolves = table::borrow(&pack.items, i);
            let wolves_length = vec::length(wolves);
            cumulative = cumulative + wolves_length * (i as u64);
            // if the value is not inside of that bucket, keep going
            if (bucket < cumulative) {
                // get the address of a random Wolf with that alpha score
                return vec::borrow(wolves, random::rand_u64_with_seed(seed) % wolves_length).owner
            };
            i = i + 1;
        };
        @0x0
    }

    // tracks $EGG earnings to ensure it stops once 1.4 million is eclipsed
    // FIXME use timestamp instead of epoch once sui team has supported timestamp
    // currently epoch will be update about every 24 hours,
    fun update_earnings(barn_registry: &mut BarnRegistry, ctx: &mut TxContext) {
        let timenow = timestamp_now(ctx);
        assert!(timenow <= barn_registry.last_claim_timestamp, ENOT_IN_PACK_OR_BARN);
        if (barn_registry.total_egg_earned < MAXIMUM_GLOBAL_EGG) {
            barn_registry.total_egg_earned = barn_registry.total_egg_earned +
                (timenow - barn_registry.last_claim_timestamp)
                    * barn_registry.total_chicken_staked * DAILY_WOOL_RATE / ONE_DAY_IN_SECOND;
            barn_registry.last_claim_timestamp = timenow;
        };
    }

    fun timestamp_now(ctx: &mut TxContext): u64 {
        tx_context::epoch(ctx)
    }

    // add $WOOL to claimable pot for the Pack
    fun pay_wolf_tax(barn_registry: &mut BarnRegistry, amount: u64) {
        if (barn_registry.total_alpha_staked == 0) {
            // if there's no staked foxed
            barn_registry.unaccounted_rewards = barn_registry.unaccounted_rewards + amount; // keep track of $WOOL due to wolves
            return
        };
        // makes sure to include any unaccounted $WOOL
        barn_registry.egg_per_alpha = barn_registry.egg_per_alpha +
            (amount + barn_registry.unaccounted_rewards) / barn_registry.total_alpha_staked;
        barn_registry.unaccounted_rewards = 0;
    }

    #[test]
    fun test_remove_fox_from_pack() {
        use sui::test_scenario;

        let dummy = @0xcafe;
        let admin = @0xBABE;

        let scenario_val = test_scenario::begin(admin);
        let scenario = &mut scenario_val;
        {
            transfer::share_object(token_helper::init_foc_registry(test_scenario::ctx(scenario)));
            transfer::share_object(init_pack(test_scenario::ctx(scenario)));
        };
        test_scenario::next_tx(scenario, dummy);
        {
            let foc_registry = test_scenario::take_shared<FoCRegistry>(scenario);
            let item = token_helper::create_foc(&mut foc_registry, test_scenario::ctx(scenario));
            let item_id = object::id(&item);
            let pack = test_scenario::take_shared<Pack>(scenario);
            add_fox_to_pack(&mut pack, item, test_scenario::ctx(scenario));

            assert!(table::contains(&pack.pack_indices, item_id), 1);

            let item_out = remove_fox_from_pack(&mut pack, item_id, test_scenario::ctx(scenario));
            assert!(!table::contains(&pack.pack_indices, item_id), 1);

            transfer::transfer(item_out, dummy);
            test_scenario::return_shared(foc_registry);
            test_scenario::return_shared(pack);
        };
        test_scenario::end(scenario_val);
    }
}