module multi_sig_treasury::policy_manager;

use sui::tx_context::{Self, TxContext};
use sui::object::{Self, UID, ID};
use sui::clock::{Self, Clock};
use sui::event;
use std::string::String;

use multi_sig_treasury::treasury::{Self, Treasury, PolicyAdminCap};
use multi_sig_treasury::common::{Self, TransactionBatch};

friend multi_sig_treasury::proposal;
friend multi_sig_treasury::emergency;

/// Policy types enum
public enum PolicyType has store, drop, copy {
    SpendingLimit,
    Whitelist,
    Category,
    TimeLock,
    AmountThreshold,
    Approval,
}

/// Policy configuration union
public enum Policy has store, drop {
    SpendingLimit(SpendingLimitConfig),
    Whitelist(WhitelistConfig),
    Category(CategoryConfig),
    TimeLock(TimeLockConfig),
    AmountThreshold(AmountThresholdConfig),
    Approval(ApprovalConfig),
}

/// PolicyManager shared object
public struct PolicyManager has key, store {
    id: UID,
    treasury_id: ID,
    policies: vector<Policy>, // Active policies
}

/// Configuration structs for each policy type

/// Spending Limit Policy - limits per category and period
public struct SpendingLimitConfig has store, drop {
    category: String, // "*" for global
    period_type: u8,  // 0=daily, 1=weekly, 2=monthly
    limit_amount: u64,
}

/// Whitelist Policy - approved recipients
public struct WhitelistConfig has store, drop {
    category: String, // "*" for all categories
    allowed_addresses: vector<address>,
    blocked_addresses: vector<address>, // Blacklist
}

/// Category Policy - required category assignment
public struct CategoryConfig has store, drop {
    allowed_categories: vector<String>,
    require_category: bool,
}

/// TimeLock Policy - minimum delay based on amount
public struct TimeLockConfig has store, drop {
    category: String, // "*" for all
    base_delay_ms: u64,
    amount_factor: u64, // delay = base + (amount / factor)
}

/// AmountThreshold Policy - different thresholds for amount ranges
public struct AmountThresholdConfig has store, drop {
    category: String, // "*" for all
    ranges: vector<AmountRange>, // sorted by min_amount
}

/// Amount range with specific threshold
public struct AmountRange has store, drop {
    min_amount: u64,
    max_amount: u64, // 0 for unlimited
    required_signers: u64,
}

/// Approval Policy - required specific signers or veto power
public struct ApprovalConfig has store, drop {
    category: String, // "*" for all
    required_signers: vector<address>, // Must include these
    veto_signers: vector<address>, // Any can block
}

/// Events
public struct PolicyManagerCreated has copy, drop {
    policy_manager_id: ID,
    treasury_id: ID,
}

public struct PolicyAdded has copy, drop {
    policy_manager_id: ID,
    policy_type: u8, // index of PolicyType
    policy_index: u64,
}

public struct PolicyRemoved has copy, drop {
    policy_manager_id: ID,
    policy_index: u64,
}

/// Create new PolicyManager
public fun create_policy_manager(
    treasury: &Treasury,
    _admin_cap: &PolicyAdminCap,
    ctx: &mut TxContext
): PolicyManager {
    let policy_manager = PolicyManager {
        id: object::new(ctx),
        treasury_id: object::id(treasury),
        policies: vector::empty(),
    };

    event::emit(PolicyManagerCreated {
        policy_manager_id: object::id(&policy_manager),
        treasury_id: object::id(treasury),
    });

    policy_manager
}

/// Add policy to manager
public fun add_policy(
    policy_manager: &mut PolicyManager,
    treasury: &Treasury,
    admin_cap: &PolicyAdminCap,
    policy: Policy,
    ctx: &mut TxContext
) {
    assert!(object::id(treasury) == policy_manager.treasury_id, 1);
    assert!(admin_cap.treasury_id == policy_manager.treasury_id, 2); // Validate admin capability

    vector::push_back(&mut policy_manager.policies, policy);

    let policy_type = match (&policy) {
        Policy::SpendingLimit(_) => 0,
        Policy::Whitelist(_) => 1,
        Policy::Category(_) => 2,
        Policy::TimeLock(_) => 3,
        Policy::AmountThreshold(_) => 4,
        Policy::Approval(_) => 5,
    };

    event::emit(PolicyAdded {
        policy_manager_id: object::id(policy_manager),
        policy_type,
        policy_index: vector::length(&policy_manager.policies) - 1,
    });
}

/// Remove policy from manager
public fun remove_policy(
    policy_manager: &mut PolicyManager,
    treasury: &Treasury,
    admin_cap: &PolicyAdminCap,
    policy_index: u64,
    ctx: &mut TxContext
) {
    assert!(object::id(treasury) == policy_manager.treasury_id, 3);
    assert!(admin_cap.treasury_id == policy_manager.treasury_id, 5); // Validate admin capability
    assert!(policy_index < vector::length(&policy_manager.policies), 4);

    vector::remove(&mut policy_manager.policies, policy_index);

    event::emit(PolicyRemoved {
        policy_manager_id: object::id(policy_manager),
        policy_index,
    });
}

/// Validate proposal against all active policies
public fun validate_proposal(
    policy_manager: &PolicyManager,
    treasury: &Treasury,
    batch: &TransactionBatch,
    clock: &Clock,
    proposer: address
) {
    let policies = &policy_manager.policies;
    let mut i = 0;
    while (i < vector::length(policies)) {
        let policy = vector::borrow(policies, i);
        validate_single_policy(policy, treasury, batch, clock, proposer);
        i = i + 1;
    };
}

/// Validate against single policy
fun validate_single_policy(
    policy: &Policy,
    treasury: &Treasury,
    batch: &TransactionBatch,
    clock: &Clock,
    proposer: address
) {
    match (policy) {
        Policy::SpendingLimit(config) => validate_spending_limit(config, treasury, batch, clock),
        Policy::Whitelist(config) => validate_whitelist(config, batch),
        Policy::Category(config) => validate_category(config, batch),
        Policy::TimeLock(config) => validate_time_lock(config, batch, clock),
        Policy::AmountThreshold(config) => validate_amount_threshold(config, treasury, batch),
        Policy::Approval(config) => validate_approval(config, treasury, batch, proposer),
    };
}

/// Spending Limit Policy validation
fun validate_spending_limit(
    config: &SpendingLimitConfig,
    treasury: &Treasury,
    batch: &TransactionBatch,
    clock: &Clock
) {
    let category = common::get_batch_category(batch);
    let total_amount = common::get_batch_total_amount(batch);
    let timestamp = clock::timestamp_ms(clock);

    // Check if policy applies to this category
    if (config.category != b"*") {
        if (config.category != *category) {
            return; // Policy doesn't apply
        };
    };

    // Calculate period ID
    let period_id = match (config.period_type) {
        0 => timestamp / (24 * 60 * 60 * 1000), // Daily
        1 => timestamp / (7 * 24 * 60 * 60 * 1000), // Weekly
        2 => timestamp / (30 * 24 * 60 * 60 * 1000), // Monthly
        _ => abort 6,
    };

    // Get current spending for period
    let current_spent = treasury::get_spending_tracker(treasury, *category, config.period_type, period_id);

    // Check limit
    assert!(current_spent + total_amount <= config.limit_amount, 7);
}

/// Whitelist Policy validation
fun validate_whitelist(
    config: &WhitelistConfig,
    batch: &TransactionBatch
) {
    let category = common::get_batch_category(batch);

    // Check if policy applies
    if (config.category != b"*") {
        if (config.category != *category) {
            return;
        };
    };

    let txs = common::get_batch_transactions(batch);
    let mut i = 0;
    while (i < vector::length(txs)) {
        let tx = vector::borrow(txs, i);
        match (tx) {
            common::Transaction::Transfer(tx_transfer) => {
                // Check if recipient is whitelisted
                if (vector::length(&config.allowed_addresses) > 0) {
                    assert!(vector::contains(&config.allowed_addresses, &tx_transfer.recipient), 8);
                };
                // Check if recipient is blacklisted
                assert!(!vector::contains(&config.blocked_addresses, &tx_transfer.recipient), 9);
            },
            common::Transaction::Call(tx_call) => {
                // Optional: validate call targets
                continue;
            }
        };
        i = i + 1;
    };
}

/// Category Policy validation
fun validate_category(
    config: &CategoryConfig,
    batch: &TransactionBatch
) {
    if (!config.require_category) {
        return;
    };

    let category = common::get_batch_category(batch);
    assert!(vector::contains(&config.allowed_categories, category), 10);
}

/// TimeLock Policy validation - this is checked at proposal level, here just ensure minimum time
fun validate_time_lock(
    config: &TimeLockConfig,
    batch: &TransactionBatch,
    clock: &Clock
) {
    let category = common::get_batch_category(batch);
    let total_amount = common::get_batch_total_amount(batch);

    // Placeholder: actual time lock validation done in proposal execution
    // Here we could validate min time requirements
    if (config.category == b"*" || config.category == *category) {
        // Calculate required delay: base + (amount / factor)
        let _required_delay = config.base_delay_ms + (total_amount / config.amount_factor);
        // This will be enforced in proposal execution
    };
}

/// AmountThreshold Policy validation
fun validate_amount_threshold(
    config: &AmountThresholdConfig,
    treasury: &Treasury,
    batch: &TransactionBatch
) {
    let category = common::get_batch_category(batch);
    let total_amount = common::get_batch_total_amount(batch);

    if (config.category != b"*" && config.category != *category) {
        return;
    };

    // Find matching range
    let ranges = &config.ranges;
    let mut i = 0;
    let mut found = false;
    let treasury_threshold = treasury::get_threshold(treasury);

    while (i < vector::length(ranges) && !found) {
        let range = vector::borrow(ranges, i);
        if (total_amount >= range.min_amount &&
            (range.max_amount == 0 || total_amount <= range.max_amount)) {
            // Check if current threshold meets requirement
            assert!(treasury_threshold >= range.required_signers, 11);
            found = true;
        };
        i = i + 1;
    };

    if (!found && vector::length(ranges) > 0) {
        abort 12; // No matching range found
    };
}

/// Approval Policy validation
fun validate_approval(
    config: &ApprovalConfig,
    treasury: &Treasury,
    batch: &TransactionBatch,
    proposer: address
) {
    let category = common::get_batch_category(batch);

    if (config.category != b"*" && config.category != *category) {
        return;
    };

    // For veto check, we would need to see who signed, but this is initial validation
    // Actual veto enforcement happens during signing

    // Can add additional checks here
}

/// Get policies (for external access)
public fun get_policies(policy_manager: &PolicyManager): &vector<Policy> {
    &policy_manager.policies
}

/// Test destroy functions
#[test_only]
public fun destroy_policy_manager(policy_manager: PolicyManager) {
    let PolicyManager { id, treasury_id: _, policies: _ } = policy_manager;
    object::delete(id);
}
