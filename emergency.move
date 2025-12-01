module multi_sig_treasury::emergency;

use sui::tx_context::{Self, TxContext};
use sui::object::{Self, UID, ID};
use sui::clock::{Self, Clock};
use sui::sui::SUI;
use sui::coin::{Self, Coin};
use sui::transfer;
use sui::event;
use std::string::String;

use multi_sig_treasury::treasury::{Self, Treasury, EmergencyCap};
use multi_sig_treasury::common::{Self, TransactionBatch};

/// Emergency capabilities
public struct EmergencyCap has key, store {
    id: UID,
    treasury_id: ID,
}

/// Emergency configuration stored on treasury as dynamic field
public struct EmergencyConfig has store {
    emergency_signers: vector<address>,
    emergency_threshold: u64, // Higher threshold for emergency
    last_emergency_timestamp: u64,
    cooldown_period_ms: u64, // Time between emergencies
    is_frozen: bool,
    freeze_timestamp: u64,
}

/// Emergency proposal for critical withdrawals
public struct EmergencyProposal has key, store {
    id: UID,
    treasury_id: ID,
    creator: address,
    emergency_withdrawal: EmergencyWithdrawal,
    signed_by: vector<address>,
    status: EmergencyStatus,
    created_at: u64,
    justification: String,
}

/// Emergency withdrawal details
public struct EmergencyWithdrawal has store, drop {
    recipient: address,
    amount: u64,
    coin_type: String, // Type name
}

/// Emergency status
public enum EmergencyStatus has store, drop, copy {
    Pending,
    Signed,
    Executed,
    Cancelled,
    Expired,
}

/// Events
public struct EmergencyConfigUpdated has copy, drop {
    treasury_id: ID,
    emergency_signers: vector<address>,
    emergency_threshold: u64,
}

public struct TreasuryFrozen has copy, drop {
    treasury_id: ID,
    frozen_by: address,
    timestamp: u64,
}

public struct TreasuryUnfrozen has copy, drop {
    treasury_id: ID,
    unfrozen_by: address,
    timestamp: u64,
}

public struct EmergencyProposalCreated has copy, drop {
    proposal_id: ID,
    treasury_id: ID,
    creator: address,
    amount: u64,
}

public struct EmergencyExecuted has copy, drop {
    proposal_id: ID,
    executor: address,
    amount: u64,
    timestamp: u64,
}

/// Initialize emergency configuration for treasury
public fun initialize_emergency_config(
    treasury: &mut Treasury,
    emergency_signers: vector<address>,
    emergency_threshold: u64,
    cooldown_period_ms: u64,
    _cap: &EmergencyCap,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(vector::length(&emergency_signers) > 0, 1);
    assert!(emergency_threshold > 0 && emergency_threshold <= vector::length(&emergency_signers), 2);

    let config = EmergencyConfig {
        emergency_signers,
        emergency_threshold,
        last_emergency_timestamp: 0,
        cooldown_period_ms,
        is_frozen: false,
        freeze_timestamp: 0,
    };

    // Store config on treasury as dynamic field
    sui::dynamic_object_field::add(&mut treasury.id, b"emergency_config", config);

    event::emit(EmergencyConfigUpdated {
        treasury_id: object::id(treasury),
        emergency_signers,
        emergency_threshold,
    });
}

/// Update emergency configuration
public fun update_emergency_config(
    treasury: &mut Treasury,
    emergency_signers: vector<address>,
    emergency_threshold: u64,
    cooldown_period_ms: u64,
    _cap: &EmergencyCap,
    ctx: &mut TxContext
) {
    assert!(vector::length(&emergency_signers) > 0, 3);
    assert!(emergency_threshold > 0 && emergency_threshold <= vector::length(&emergency_signers), 4);

    let mut config: EmergencyConfig = sui::dynamic_object_field::remove(&mut treasury.id, b"emergency_config");

    config.emergency_signers = emergency_signers;
    config.emergency_threshold = emergency_threshold;
    config.cooldown_period_ms = cooldown_period_ms;

    // Put back updated config
    sui::dynamic_object_field::add(&mut treasury.id, b"emergency_config", config);

    event::emit(EmergencyConfigUpdated {
        treasury_id: object::id(treasury),
        emergency_signers,
        emergency_threshold,
    });
}

/// Freeze treasury - immediate action
public fun freeze_treasury(
    treasury: &mut Treasury,
    _cap: &EmergencyCap,
    clock: &Clock,
    ctx: &mut TxContext
) {
    let mut config: EmergencyConfig = sui::dynamic_object_field::remove(&mut treasury.id, b"emergency_config");

    // Verify sender is emergency signer
    let sender = tx_context::sender(ctx);
    assert!(vector::contains(&config.emergency_signers, &sender), 5);

    config.is_frozen = true;
    config.freeze_timestamp = clock::timestamp_ms(clock);

    sui::dynamic_object_field::add(&mut treasury.id, b"emergency_config", config);

    event::emit(TreasuryFrozen {
        treasury_id: object::id(treasury),
        frozen_by: sender,
        timestamp: clock::timestamp_ms(clock),
    });
}

/// Unfreeze treasury
public fun unfreeze_treasury(
    treasury: &mut Treasury,
    _cap: &EmergencyCap,
    ctx: &mut TxContext
) {
    // Require all emergency signers to unfreeze
    let mut config: EmergencyConfig = sui::dynamic_object_field::remove(&mut treasury.id, b"emergency_config");

    // Placeholder: should check all emergency signers approve
    let sender = tx_context::sender(ctx);
    assert!(vector::contains(&config.emergency_signers, &sender), 6);

    config.is_frozen = false;

    sui::dynamic_object_field::add(&mut treasury.id, b"emergency_config", config);

    event::emit(TreasuryUnfrozen {
        treasury_id: object::id(treasury),
        unfrozen_by: sender,
        timestamp: 0, // TODO: pass clock
    });
}

/// Create emergency proposal
public fun create_emergency_proposal(
    treasury: &Treasury,
    withdrawal: EmergencyWithdrawal,
    justification: String,
    clock: &Clock,
    ctx: &mut TxContext
): EmergencyProposal {
    // Check cooldown period
    let config: &EmergencyConfig = sui::dynamic_object_field::borrow(&treasury.id, b"emergency_config");
    let sender = tx_context::sender(ctx);
    assert!(vector::contains(&config.emergency_signers, &sender), 7);

    let current_time = clock::timestamp_ms(clock);
    assert!(current_time >= config.last_emergency_timestamp + config.cooldown_period_ms, 8);

    let proposal = EmergencyProposal {
        id: object::new(ctx),
        treasury_id: object::id(treasury),
        creator: sender,
        emergency_withdrawal: withdrawal,
        signed_by: vector::empty(),
        status: EmergencyStatus::Pending,
        created_at: current_time,
        justification,
    };

    event::emit(EmergencyProposalCreated {
        proposal_id: object::id(&proposal),
        treasury_id: object::id(treasury),
        creator: sender,
        amount: withdrawal.amount,
    });

    proposal
}

/// Sign emergency proposal
public fun sign_emergency_proposal(
    proposal: &mut EmergencyProposal,
    treasury: &Treasury,
    ctx: &mut TxContext
) {
    assert!(match (&proposal.status) { EmergencyStatus::Pending => true, _ => false }, 9);

    let config: &EmergencyConfig = sui::dynamic_object_field::borrow(&treasury.id, b"emergency_config");
    let signer = tx_context::sender(ctx);
    assert!(vector::contains(&config.emergency_signers, &signer), 10);
    assert!(!vector::contains(&proposal.signed_by, &signer), 11);

    vector::push_back(&mut proposal.signed_by, signer);

    if (vector::length(&proposal.signed_by) >= config.emergency_threshold) {
        proposal.status = EmergencyStatus::Signed;
    };
}

/// Execute emergency withdrawal
public fun execute_emergency_withdrawal(
    proposal: &mut EmergencyProposal,
    treasury: &mut Treasury,
    clock: &Clock,
    ctx: &mut TxContext
) {
    assert!(match (&proposal.status) { EmergencyStatus::Signed => true, _ => false }, 12);

    let config: &EmergencyConfig = sui::dynamic_object_field::borrow(&treasury.id, b"emergency_config");
    let executor = tx_context::sender(ctx);
    assert!(vector::contains(&config.emergency_signers, &executor), 13);

    // Check if treasury is frozen (emergency withdrawals allowed when frozen)
    // assert!(!config.is_frozen, 14); // Emergency can execute even when frozen

    let current_time = clock::timestamp_ms(clock);
    assert!(current_time >= proposal.created_at + 3600000, 15); // 1 hour minimum emergency delay

    // Execute withdrawal
    let withdrawal_coin = treasury::execute_withdrawal<SUI>(
        treasury,
        proposal.emergency_withdrawal.recipient,
        proposal.emergency_withdrawal.amount,
        ctx
    );

    transfer::public_transfer(withdrawal_coin, proposal.emergency_withdrawal.recipient);

    // Update emergency timestamp for cooldown
    let mut config_mut: EmergencyConfig = sui::dynamic_object_field::remove(&mut treasury.id, b"emergency_config");
    config_mut.last_emergency_timestamp = current_time;
    sui::dynamic_object_field::add(&mut treasury.id, b"emergency_config", config_mut);

    proposal.status = EmergencyStatus::Executed;

    event::emit(EmergencyExecuted {
        proposal_id: object::id(proposal),
        executor,
        amount: proposal.emergency_withdrawal.amount,
        timestamp: current_time,
    });
}

/// Check if treasury is frozen
public fun is_treasury_frozen(treasury: &Treasury): bool {
    if (!sui::dynamic_object_field::exists_(&treasury.id, b"emergency_config")) {
        return false;
    };

    let config: &EmergencyConfig = sui::dynamic_object_field::borrow(&treasury.id, b"emergency_config");
    config.is_frozen
}

/// Get emergency config
public fun get_emergency_config(treasury: &Treasury): &EmergencyConfig {
    sui::dynamic_object_field::borrow(&treasury.id, b"emergency_config")
}

/// Cancel emergency proposal
public fun cancel_emergency_proposal(
    proposal: &mut EmergencyProposal,
    treasury: &Treasury,
    ctx: &mut TxContext
) {
    let sender = tx_context::sender(ctx);
    assert!(sender == proposal.creator || vector::contains(&get_emergency_config(treasury).emergency_signers, &sender), 16);

    proposal.status = EmergencyStatus::Cancelled;
}

/// Test destroy functions
#[test_only]
public fun destroy_emergency_cap(cap: EmergencyCap) {
    let EmergencyCap { id, treasury_id: _ } = cap;
    object::delete(id);
}

#[test_only]
public fun destroy_emergency_proposal(proposal: EmergencyProposal) {
    let EmergencyProposal {
        id,
        treasury_id: _,
        creator: _,
        emergency_withdrawal: _,
        signed_by: _,
        status: _,
        created_at: _,
        justification: _,
    } = proposal;
    object::delete(id);
}

// Helper constructor for EmergencyWithdrawal
public fun new_emergency_withdrawal(recipient: address, amount: u64, coin_type: String): EmergencyWithdrawal {
    EmergencyWithdrawal { recipient, amount, coin_type }
}
