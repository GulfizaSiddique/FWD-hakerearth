module multi_sig_treasury::treasury;

use sui::tx_context::{Self, TxContext};
use sui::dynamic_object_field as dof;
use sui::object::{Self, UID, ID};
use sui::table::{Self, Table, drop};
use sui::vec_map::{Self, VecMap};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::clock::{Self, Clock};
use std::type_name;
use std::ascii::String;

friend multi_sig_treasury::proposal;

/// Capabilities for access control
public struct TreasuryAdminCap has key, store {
    id: UID,
    treasury_id: ID,
}

public struct TreasurySignerCap has key, store {
    id: UID,
    treasury_id: ID,
}

public struct PolicyAdminCap has key, store {
    id: UID,
    treasury_id: ID,
}

public struct EmergencyCap has key, store {
    id: UID,
    treasury_id: ID,
}

/// Treasury object - the main shared object
public struct Treasury has key, store {
    id: UID,
    name: String,
    description: String,
    signers: vector<address>,
    threshold: u64, // number of signatures required (not percentage to match PRD)
    // Balances stored as dynamic fields: CoinType -> Balance<CoinType>
    // Spending trackers: (category, period_type, period_id) -> amount_spent
    // period_type: 0=daily, 1=weekly, 2=monthly
}

/// Events
public struct TreasuryCreated has copy, drop {
    treasury_id: ID,
    creator: address,
}

public struct Deposit has copy, drop {
    treasury_id: ID,
    depositor: address,
    coin_type: String,
    amount: u64,
}

public struct Withdrawal has copy, drop {
    treasury_id: ID,
    recipient: address,
    coin_type: String,
    amount: u64,
}

/// Create a new treasury
public fun create_treasury(
    name: String,
    description: String,
    signers: vector<address>,
    threshold: u64,
    ctx: &mut TxContext
): (Treasury, TreasuryAdminCap, TreasurySignerCap, PolicyAdminCap, EmergencyCap) {
    // Validate inputs
    assert!(vector::length(&signers) > 0, 1); // At least one signer
    assert!(threshold > 0 && threshold <= vector::length(&signers), 2); // Valid threshold
    // Ensure no duplicate signers
    let mut signer_set = vec_map::empty<address, bool>();
    let mut i = 0;
    while (i < vector::length(&signers)) {
        let signer = *vector::borrow(&signers, i);
        assert!(!vec_map::contains(&signer_set, &signer), 3); // No duplicates
        vec_map::insert(&mut signer_set, signer, true);
        i = i + 1;
    };
    vec_map::destroy_empty(signer_set);

    // Create treasury object
    let treasury = Treasury {
        id: object::new(ctx),
        name,
        description,
        signers,
        threshold,
    };

    let treasury_id = object::id(&treasury);

    // Emit event
    event::emit(TreasuryCreated {
        treasury_id,
        creator: tx_context::sender(ctx),
    });

    // Return treasury and capabilities
    let admin_cap = TreasuryAdminCap {
        id: object::new(ctx),
        treasury_id,
    };
    let signer_cap = TreasurySignerCap {
        id: object::new(ctx),
        treasury_id,
    };
    let policy_cap = PolicyAdminCap {
        id: object::new(ctx),
        treasury_id,
    };
    let emergency_cap = EmergencyCap {
        id: object::new(ctx),
        treasury_id,
    };

    (treasury, admin_cap, signer_cap, policy_cap, emergency_cap)
}

/// Entry function to create and share treasury
public entry fun create_treasury_entry(
    name: String,
    description: String,
    signers: vector<address>,
    threshold: u64,
    ctx: &mut TxContext
) {
    let (treasury, admin_cap, signer_cap, policy_cap, emergency_cap) = create_treasury(
        name, description, signers, threshold, ctx
    );
    sui::transfer::share_object(treasury);
    sui::transfer::transfer(admin_cap, tx_context::sender(ctx));
    sui::transfer::transfer(signer_cap, tx_context::sender(ctx));
    sui::transfer::transfer(policy_cap, tx_context::sender(ctx));
    sui::transfer::transfer(emergency_cap, tx_context::sender(ctx));
}

/// Deposit coins to treasury
public fun deposit_coin<CoinType>(
    treasury: &mut Treasury,
    coin: Coin<CoinType>,
    ctx: &mut TxContext
) {
    let amount = coin::value(&coin);
    let coin_type_str = *type_name::into_string(type_name::get<CoinType>());

    // Try to get existing balance
    if (dof::exists_(&treasury.id, coin_type_str)) {
        let mut balance: Balance<CoinType> = dof::remove(&mut treasury.id, coin_type_str);
        coin::put(&mut balance, coin);
        dof::add(&mut treasury.id, coin_type_str, balance);
    } else {
        let balance = coin::into_balance(coin);
        dof::add(&mut treasury.id, coin_type_str, balance);
    };

    event::emit(Deposit {
        treasury_id: object::id(treasury),
        depositor: tx_context::sender(ctx),
        coin_type: coin_type_str,
        amount,
    });
}

/// Entry function to deposit SUI
public entry fun deposit_sui(
    treasury: &mut Treasury,
    coin: Coin<SUI>,
    ctx: &mut TxContext
) {
    deposit_coin(treasury, coin, ctx);
}

/// Get balance by coin type
public fun get_balance<CoinType>(treasury: &Treasury): u64 {
    let coin_type_str = type_name::into_string(type_name::get<CoinType>());
    if (dof::exists_(&treasury.id, coin_type_str)) {
        let balance: &Balance<CoinType> = dof::borrow(&treasury.id, coin_type_str);
        balance::value(balance)
    } else {
        0
    }
}

/// Internal function to execute withdrawal (used by proposal module)
public(friend) fun execute_withdrawal<CoinType>(
    treasury: &mut Treasury,
    recipient: address,
    amount: u64,
    ctx: &mut TxContext
): Coin<CoinType> {
    let coin_type_str = type_name::into_string(type_name::get<CoinType>());
    assert!(dof::exists_(&treasury.id, coin_type_str), 4); // Coin type exists
    
    let mut balance: Balance<CoinType> = dof::remove(&mut treasury.id, coin_type_str);
    assert!(balance::value(&balance) >= amount, 5); // Sufficient funds
    
    let withdraw_coin = coin::from_balance(balance::split(&mut balance, amount), ctx);
    
    // Put back remaining balance
    if (balance::value(&balance) > 0) {
        dof::add(&mut treasury.id, coin_type_str, balance);
    } else {
        balance::destroy_zero(balance);
    };

    event::emit(Withdrawal {
        treasury_id: object::id(treasury),
        recipient,
        coin_type: coin_type_str,
        amount,
    });

    withdraw_coin
}

/// Helper: get spending tracker key for (category, period_type, period_id)
public fun get_tracker_key(category: String, period_type: u8, period_id: u64): String {
    let mut key = category;
    string::append(&mut key, b"_");
    string::append(&mut key, std::string::from_ascii(std::ascii::string(vector[ period_type + 48 ])));
    string::append(&mut key, b"_");
    string::append(&mut key, std::string::utf8(vector::singleton(period_id as u32)));
    key
}

/// Update spending tracker
public(friend) fun update_spending_tracker(
    treasury: &mut Treasury,
    category: String,
    amount: u64,
    clock: &Clock
) {
    // Get current timestamp for periods
    let timestamp = clock::timestamp_ms(clock);
    
    // Daily period
    let daily_period = timestamp / (24 * 60 * 60 * 1000);
    let tracker_key_daily = get_tracker_key(category, 0, daily_period);
    update_tracker(treasury, tracker_key_daily, amount);
    
    // Weekly period (7 days)
    let weekly_period = timestamp / (7 * 24 * 60 * 60 * 1000);
    let tracker_key_weekly = get_tracker_key(category, 1, weekly_period);
    update_tracker(treasury, tracker_key_weekly, amount);
    
    // Monthly period (30 days approx)
    let monthly_period = timestamp / (30 * 24 * 60 * 60 * 1000);
    let tracker_key_monthly = get_tracker_key(category, 2, monthly_period);
    update_tracker(treasury, tracker_key_monthly, amount);
}

/// Helper to update individual tracker
fun update_tracker(treasury: &mut Treasury, key: String, amount: u64) {
    if (dof::exists_(&treasury.id, key)) {
        let mut current_amount: u64 = dof::remove(&mut treasury.id, key);
        current_amount = current_amount + amount;
        dof::add(&mut treasury.id, key, current_amount);
    } else {
        dof::add(&mut treasury.id, key, amount);
    };
}

/// Get spending for period
public fun get_spending_tracker(
    treasury: &Treasury,
    category: String,
    period_type: u8,
    period_id: u64
): u64 {
    let tracker_key = get_tracker_key(category, period_type, period_id);
    if (dof::exists_(&treasury.id, tracker_key)) {
        *dof::borrow(&treasury.id, tracker_key)
    } else {
        0
    }
}

/// Reset spending trackers (called periodically by policy manager keeper)
public(friend) fun reset_expired_trackers(treasury: &mut Treasury, current_timestamp: u64) {
    // TODO: Implement clean up of old trackers (complex with dynamic fields)
    // For now, rely on batch cleanup or external keeper
}

/// Public getters
public fun get_signers(treasury: &Treasury): &vector<address> {
    &treasury.signers
}

public fun get_threshold(treasury: &Treasury): u64 {
    treasury.threshold
}

/// Destroy treasury (for testing only)
#[test_only]
public fun destroy_treasury(treasury: Treasury) {
    let Treasury { id, name: _, description: _, signers: _, threshold: _ } = treasury;
    object::delete(id);
}

/// Test only destroy cap
#[test_only]
public fun destroy_admin_cap(cap: TreasuryAdminCap) {
    let TreasuryAdminCap { id, treasury_id: _ } = cap;
    object::delete(id);
}

#[test_only]
public fun destroy_signer_cap(cap: TreasurySignerCap) {
    let TreasurySignerCap { id, treasury_id: _ } = cap;
    object::delete(id);
}

#[test_only]
public fun destroy_policy_cap(cap: PolicyAdminCap) {
    let PolicyAdminCap { id, treasury_id: _ } = cap;
    object::delete(id);
}

#[test_only]
public fun destroy_emergency_cap(cap: EmergencyCap) {
    let EmergencyCap { id, treasury_id: _ } = cap;
    object::delete(id);
}
