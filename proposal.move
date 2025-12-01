module multi_sig_treasury::proposal;

use sui::tx_context::{Self, TxContext};
use sui::object::{Self, UID, ID};
use sui::vec_map::{Self, VecMap};
use sui::event;
use sui::clock::{Self, Clock};
use sui::sui::SUI;
use sui::coin::{Self, Coin};
use sui::transfer;
use std::string::String;

use multi_sig_treasury::treasury::{Self, Treasury, TreasurySignerCap};
use multi_sig_treasury::policy_manager::{Self, PolicyManager};
use multi_sig_treasury::common::{Self, TransactionBatch, Transaction};

friend multi_sig_treasury::emergency;

/// Proposal states
public enum ProposalStatus has store, drop, copy {
    Pending,
    Signed,
    Executed,
    Cancelled,
    Rejected,
}

/// Proposal object (owned by the proposer)
public struct Proposal has key, store {
    id: UID,
    treasury_id: ID,
    proposer: address,
    batch: TransactionBatch,
    signed_by: vector<address>, // Signers who approved
    status: ProposalStatus,
    created_at: u64, // Timestamp in ms
    time_lock_duration: u64, // Minimum delay in ms before execution
    execution_deadline: u64, // Max time to execute (for expiry)
}

/// Proposal capabilities
public struct ProposalCap has key, store {
    id: UID,
    proposal_id: ID,
}

/// Events
public struct ProposalCreated has copy, drop {
    proposal_id: ID,
    treasury_id: ID,
    proposer: address,
    category: String,
    total_amount: u64,
}

public struct ProposalSigned has copy, drop {
    proposal_id: ID,
    signer: address,
}

public struct ProposalExecuted has copy, drop {
    proposal_id: ID,
    executor: address,
    success: bool,
}

public struct ProposalCancelled has copy, drop {
    proposal_id: ID,
    cancelled_by: address,
}

/// Create new proposal
public fun create_proposal(
    treasury: &Treasury,
    batch: TransactionBatch,
    time_lock_duration: u64, // e.g., 24 * 60 * 60 * 1000 for 1 day
    policy_manager: &PolicyManager,
    clock: &Clock,
    ctx: &mut TxContext
): (Proposal, ProposalCap) {
    // Validate batch size <= 50
    assert!(vector::length(&batch.transactions) <= 50, 1);
    assert!(vector::length(&batch.transactions) > 0, 2);

    // Validate proposal against policies
    policy_manager::validate_proposal(policy_manager, treasury, &batch, clock, ctx.sender());

    let proposal = Proposal {
        id: object::new(ctx),
        treasury_id: object::id(treasury),
        proposer: ctx.sender(),
        batch,
        signed_by: vector::empty(),
        status: ProposalStatus::Pending,
        created_at: clock::timestamp_ms(clock),
        time_lock_duration,
        execution_deadline: clock::timestamp_ms(clock) + (30 * 24 * 60 * 60 * 1000), // 30 days expiry
    };

    let proposal_id = object::id(&proposal);

    event::emit(ProposalCreated {
        proposal_id,
        treasury_id: object::id(treasury),
        proposer: ctx.sender(),
        category: *common::get_batch_category(&batch),
        total_amount: common::get_batch_total_amount(&batch),
    });

    let cap = ProposalCap {
        id: object::new(ctx),
        proposal_id,
    };

    (proposal, cap)
}

/// Entry function to create proposal
public entry fun create_proposal_entry(
    treasury: &Treasury,
    category: String,
    transactions: vector<Transaction>,
    metadata: String,
    time_lock_duration: u64,
    policy_manager: &PolicyManager,
    clock: &Clock,
    ctx: &mut TxContext
) {
    let batch = common::new_transaction_batch(category, transactions, metadata);
    let (proposal, cap) = create_proposal(
        treasury, batch, time_lock_duration, policy_manager, clock, ctx
    );
    sui::transfer::transfer(proposal, tx_context::sender(ctx));
    sui::transfer::transfer(cap, tx_context::sender(ctx));
}

/// Sign proposal (can be called multiple times by different signers)
public fun sign_proposal(
    proposal: &mut Proposal,
    treasury: &Treasury,
    _signer_cap: &TreasurySignerCap, // Capability to verify signer
    ctx: &mut TxContext
) {
    // Validate proposal status
    assert!(match (&proposal.status) {
        ProposalStatus::Pending => true,
        _ => false
    }, 3);

    // Verify signer is authorized
    let signer = tx_context::sender(ctx);
    assert!(vector::contains(treasury::get_signers(treasury), &signer), 4);

    // Check not already signed
    assert!(!vector::contains(&proposal.signed_by, &signer), 5);

    // Add signature
    vector::push_back(&mut proposal.signed_by, signer);

    // Update status
    let threshold = treasury::get_threshold(treasury);
    if (vector::length(&proposal.signed_by) >= threshold) {
        proposal.status = ProposalStatus::Signed;
    };

    event::emit(ProposalSigned {
        proposal_id: object::id(proposal),
        signer,
    });
}

/// Entry function to sign proposal
public entry fun sign_proposal_entry(
    proposal: &mut Proposal,
    treasury: &Treasury,
    signer_cap: &TreasurySignerCap,
    ctx: &mut TxContext
) {
    sign_proposal(proposal, treasury, signer_cap, ctx);
}

/// Execute proposal
public fun execute_proposal(
    proposal: &mut Proposal,
    treasury: &mut Treasury,
    policy_manager: &mut PolicyManager,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // Validate status
    assert!(match (&proposal.status) {
        ProposalStatus::Signed => true,
        _ => false
    }, 6);

    // Check time-lock
    let current_time = clock::timestamp_ms(clock);
    assert!(current_time >= proposal.created_at + proposal.time_lock_duration, 7);

    // Check not expired
    assert!(current_time <= proposal.execution_deadline, 8);

    // Final policy validation just before execution
    policy_manager::validate_proposal(policy_manager, treasury, &proposal.batch, clock, tx_context::sender(ctx));

    // Execute transactions
    let success = execute_batch_transactions(&proposal.batch, treasury, clock, ctx);

    // Update spending trackers
    treasury::update_spending_tracker(
        treasury,
        *common::get_batch_category(&proposal.batch),
        common::get_batch_total_amount(&proposal.batch),
        clock
    );

    // Update status
    proposal.status = ProposalStatus::Executed;

    event::emit(ProposalExecuted {
        proposal_id: object::id(proposal),
        executor: tx_context::sender(ctx),
        success,
    });

    // Mark proposal cap as executed or destroy
}

/// Entry function to execute proposal
public entry fun execute_proposal_entry(
    proposal: &mut Proposal,
    treasury: &mut Treasury,
    policy_manager: &mut PolicyManager,
    clock: &Clock,
    ctx: &mut TxContext
) {
    execute_proposal(proposal, treasury, policy_manager, clock, ctx);
}

/// Cancel proposal (by proposer or all current signers)
public fun cancel_proposal(
    proposal: &mut Proposal,
    treasury: &Treasury,
    cap: ProposalCap, // Only proposer can cancel via cap
    ctx: &mut TxContext
) {
    assert!(object::id(proposal) == cap.proposal_id, 9);

    let canceller = tx_context::sender(ctx);
    let is_proposer = canceller == proposal.proposer;
    let is_unanimous = all_signers_approved(proposal, treasury);

    assert!(is_proposer || is_unanimous, 10);

    proposal.status = ProposalStatus::Cancelled;

    event::emit(ProposalCancelled {
        proposal_id: object::id(proposal),
        cancelled_by: canceller,
    });

    // Destroy cap
    destroy_proposal_cap(cap);
}

/// Helper: check if all current signers approved
fun all_signers_approved(proposal: &Proposal, treasury: &Treasury): bool {
    let signers = treasury::get_signers(treasury);
    let mut all_approved = true;
    let mut i = 0;
    while (i < vector::length(&signers) && all_approved) {
        let signer = *vector::borrow(&signers, i);
        if (!vector::contains(&proposal.signed_by, &signer)) {
            all_approved = false;
        };
        i = i + 1;
    };
    all_approved
}

/// Execute batch of transactions
fun execute_batch_transactions(
    batch: &TransactionBatch,
    treasury: &mut Treasury,
    clock: &Clock,
    ctx: &mut TxContext
): bool {
    let txs = common::get_batch_transactions(batch);
    let mut success = true;
    let mut i = 0;

    while (i < vector::length(txs)) {
        let tx = *vector::borrow(txs, i);
        match (tx) {
            common::Transaction::Transfer(tx_transfer) => {
                // Execute transfer - currently only support SUI
                if (tx_transfer.coin_type == b"0x2::sui::SUI") {
                    let coin_result = treasury::execute_withdrawal<SUI>(
                        treasury,
                        tx_transfer.recipient,
                        tx_transfer.amount,
                        ctx
                    );
                    transfer::public_transfer(coin_result, tx_transfer.recipient);
                } else {
                    // For now, only SUI supported. Future: add support for other fungible tokens
                    abort 20; // Unsupported coin type
                };
            },
            common::Transaction::Call(tx_call) => {
                // TODO: Implement generic call execution
                // This would require dynamic dispatch, complex in Move
                // For now, only support transfers
                continue;
            }
        };
        i = i + 1;
    };

    success
}

/// Getters (for external access)
public fun get_proposal_status(proposal: &Proposal): &ProposalStatus {
    &proposal.status
}

public fun get_signed_by(proposal: &Proposal): &vector<address> {
    &proposal.signed_by
}

public fun get_proposer(proposal: &Proposal): address {
    proposal.proposer
}

/// Destroy proposal (after execution/cancellation)
public fun destroy_proposal(proposal: Proposal) {
    let Proposal {
        id,
        treasury_id: _,
        proposer: _,
        batch: _,
        signed_by: _,
        status: _,
        created_at: _,
        time_lock_duration: _,
        execution_deadline: _,
    } = proposal;
    object::delete(id);
}

/// Destroy proposal cap
fun destroy_proposal_cap(cap: ProposalCap) {
    let ProposalCap { id, proposal_id: _ } = cap;
    object::delete(id);
}

/// Test destroy functions
#[test_only]
public fun destroy_proposal_cap_test(cap: ProposalCap) {
    destroy_proposal_cap(cap);
}
