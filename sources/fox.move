module fox_game::fox {
    use sui::sui::SUI;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{TxContext, sender};
    use sui::transfer::{transfer, share_object};
    use std::vector as vec;
    use sui::pay;
    use std::hash::sha3_256 as hash;

    use fox_game::config;
    use fox_game::token_helper::{Self, FoCRegistry, FoxOrChicken};
    use fox_game::barn::{Self, Pack, Barn, BarnRegistry};
    use fox_game::egg::{Self, EGG};
    use std::vector;

    /// The Naming Service contract is not enabled
    const ENOT_ENABLED: u64 = 1;
    /// Action not authorized because the signer is not the owner of this module
    const ENOT_AUTHORIZED: u64 = 1;
    /// The collection minting is disabled
    const EMINTING_DISABLED: u64 = 3;
    /// All minted
    const EALL_MINTED: u64 = 4;
    /// Invalid minting
    const EINVALID_MINTING: u64 = 5;
    /// INSUFFICIENT BALANCE
    const EINSUFFICIENT_SUI_BALANCE: u64 = 6;
    const EINSUFFICIENT_WOOL_BALANCE: u64 = 7;

    struct Global has key {
        id: UID,
        pack: Pack,
        barn: Barn,
        barn_registry: BarnRegistry,
        foc_registry: FoCRegistry,
    }

    fun init(ctx: &mut TxContext) {
        transfer(token_helper::init_foc_manage_cap(ctx), sender(ctx));
        share_object(Global {
            id: object::new(ctx),
            barn_registry: barn::init_barn_registry(ctx),
            pack: barn::init_pack(ctx),
            barn: barn::init_barn(ctx),
            foc_registry: token_helper::init_foc_registry(ctx),
        })
    }

    public fun mint_cost(token_index: u64): u64 {
        if (token_index <= config::paid_tokens()) {
            return 0
        } else if (token_index <= config::max_tokens() * 2 / 5) {
            return 20 * config::octas()
        } else if (token_index <= config::max_tokens() * 4 / 5) {
            return 40 * config::octas()
        };
        80 * config::octas()
    }

    /// mint a fox or chicken
    public entry fun mint(
        global: &mut Global,
        treasury_cap: &mut TreasuryCap<EGG>,
        amount: u64,
        stake: bool,
        ctx: &mut TxContext,
    ) {
        assert!(config::is_enabled(), ENOT_ENABLED);
        assert!(amount > 0 && amount <= config::max_single_mint(), EINVALID_MINTING);
        let token_supply = token_helper::total_supply(&global.foc_registry);
        assert!(token_supply + amount <= config::target_max_tokens(), EALL_MINTED);

        let receiver_addr = sender(ctx);
        // payment: vector<Coin<SUI>>
        // if (token_supply < config::paid_tokens()) {
        //     assert!(token_supply + amount <= config::paid_tokens(), EALL_MINTED);
        //     let price = config::mint_price() * amount;
        //     let (paid, remainder) = merge_and_split(payment, price, ctx);
        //     coin::put(&mut reg.balance, paid);
        //     transfer(remainder, sender(ctx))
        // };
        let id = object::new(ctx);
        let seed = hash(object::uid_to_bytes(&id));
        let total_egg_cost: u64 = 0;
        let tokens: vector<FoxOrChicken> = vec::empty<FoxOrChicken>();
        let i = 0;
        while (i < amount) {
            let token_index = token_supply + i + 1;
            let recipient: address = select_recipient(&mut global.pack, receiver_addr, seed, token_index);
            let token = token_helper::create_foc(&mut global.foc_registry, ctx);
            if (!stake || recipient != receiver_addr) {
                transfer(token, receiver_addr);
            } else {
                vec::push_back(&mut tokens, token);
            };
            // wool cost
            total_egg_cost = total_egg_cost + mint_cost(token_index);
            i = i + 1;
        };
        if (total_egg_cost > 0) {
            // burn WOOL
            // wool::register_coin(receiver);
            // assert!(coin::balance<wool::Wool>(receiver_addr) >= total_wool_cost, error::invalid_state(EINSUFFICIENT_WOOL_BALANCE));
            // wool::burn(receiver, total_wool_cost);
            // wool::transfer(receiver, @woolf_deployer, total_wool_cost);
            egg::mint(treasury_cap, total_egg_cost, receiver_addr, ctx);
        };

        if (stake) {
            barn::stake_many_to_barn_and_pack(&mut global.barn_registry, &mut global.barn, &mut global.pack, tokens, ctx);
        } else {
            vec::destroy_empty(tokens);
        };
        object::delete(id);
    }

    public entry fun add_many_to_barn_and_pack(
        global: &mut Global,
        tokens: vector<FoxOrChicken>,
        ctx: &mut TxContext,
    ) {
        barn::stake_many_to_barn_and_pack(&mut global.barn_registry, &mut global.barn, &mut global.pack, tokens, ctx);
    }

    public entry fun claim_many_from_barn_and_pack(
        global: &mut Global,
        tokens: vector<ID>,
        unstake: bool,
        ctx: &mut TxContext,
    ) {
        barn::claim_many_from_barn_and_pack(
            &mut global.barn_registry,
            &mut global.barn,
            &mut global.pack,
            tokens,
            unstake,
            ctx
        );
    }

    public entry fun claim_one_from_barn_and_pack(
        global: &mut Global,
        token: ID,
        unstake: bool,
        ctx: &mut TxContext,
    ) {
        let token_id = vector::singleton<ID>(token);
        barn::claim_many_from_barn_and_pack(
            &mut global.barn_registry,
            &mut global.barn,
            &mut global.pack,
            token_id,
            unstake,
            ctx
        );
    }

    /// Merges a vector of Coin then splits the `amount` from it, returns the
    /// Coin with the amount and the remainder.
    fun merge_and_split(
        coins: vector<Coin<SUI>>, amount: u64, ctx: &mut TxContext
    ): (Coin<SUI>, Coin<SUI>) {
        let base = vec::pop_back(&mut coins);
        pay::join_vec(&mut base, coins);
        assert!(coin::value(&base) > amount, 0);
        (coin::split(&mut base, amount, ctx), base)
    }

    // the first 20% (ETH purchases) go to the minter
    // the remaining 80% have a 10% chance to be given to a random staked wolf
    fun select_recipient(pack: &mut Pack, sender: address, seed: vector<u8>, total_supply: u64): address {
        let rand = *vec::borrow(&seed, 0) % 10;
        if (total_supply <= config::paid_tokens() || rand > 0)
            return sender; // top 10 bits haven't been used
        let thief = barn::random_wolf_owner(pack, seed);
        if (thief == @0x0) return sender;
        return thief
    }
}