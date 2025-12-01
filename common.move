module multi_sig_treasury::common;

use std::string::String;
use sui::address;

/// Transaction types for batching
public struct TransferTransaction has store, drop, copy {
    recipient: address,
    coin_type: String, // Type name string
    amount: u64,
}

public struct CallTransaction has store, drop, copy {
    package_id: address,
    module_name: String,
    function_name: String,
    arguments: vector<String>, // Serialized arguments
    type_arguments: vector<String>, // For generic calls
}

// Batch of transactions in a proposal
public struct TransactionBatch has store, drop {
    category: String, // Spending category (Operations, Marketing, etc.)
    transactions: vector<Transaction>, // Limited to 50
    total_amount: u64, // Total across all transactions (for policy checks)
    metadata: String, // Proposal description/justification
}

// Union type for transaction types
public enum Transaction has store, drop, copy {
    Transfer(TransferTransaction),
    Call(CallTransaction),
}

/// Helper functions for transactions
public fun new_transfer_transaction(
    recipient: address,
    coin_type: String,
    amount: u64,
): TransferTransaction {
    TransferTransaction { recipient, coin_type, amount }
}

public fun new_call_transaction(
    package_id: address,
    module_name: String,
    function_name: String,
    arguments: vector<String>,
    type_arguments: vector<String>,
): CallTransaction {
    CallTransaction { package_id, module_name, function_name, arguments, type_arguments }
}

/// Create transaction batch with validation
public fun new_transaction_batch(
    category: String,
    transactions: vector<Transaction>,
    metadata: String,
): TransactionBatch {
    let total_amount = calculate_total_amount(&transactions);
    TransactionBatch {
        category,
        transactions,
        total_amount,
        metadata,
    }
}

/// Calculate total amount in batch
fun calculate_total_amount(transactions: &vector<Transaction>): u64 {
    let mut total = 0u64;
    let mut i = 0u64;
    while (i < vector::length(transactions)) {
        let tx = vector::borrow(transactions, i);
        match (tx) {
            Transfer(tx_transfer) => total = total + tx_transfer.amount,
            Call(_) => {} // Call transactions don't have direct amounts
        };
        i = i + 1;
    };
    total
}

/// Getters
public fun get_batch_category(batch: &TransactionBatch): &String {
    &batch.category
}

public fun get_batch_transactions(batch: &TransactionBatch): &vector<Transaction> {
    &batch.transactions
}

public fun get_batch_total_amount(batch: &TransactionBatch): u64 {
    batch.total_amount
}

public fun get_batch_metadata(batch: &TransactionBatch): &String {
    &batch.metadata
}
