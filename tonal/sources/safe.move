module tonal::safe {
    use std::ascii;
    use std::string::String;

    use sui::math;
    use sui::clock::Clock;
    use sui::url::{Self, Url};
    use sui::object_table::{Self, ObjectTable};

    use tonal::transaction::{Self, Transaction, SecureTransaction};

    public struct Safe has key {
        id: UID,
        threshold: u64,
        /// A vector storing the owners of the safe.
        owners: vector<address>,
        /// Stores safe metadata like name, description, logo_url etc.
        metadata: SafeMetadata,
        /// The minimum amount of time that must pass before a transaction is allowed to be executed.
        execution_delay_ms: u64,
        /// The sequence number of the last voided transaction.
        last_stale_transaction: u64,
        /// A `ObjectTable` storing the safe transactions.
        transactions: ObjectTable<u64, Transaction>,
    }

    public struct SafeMetadata has store {
        /// The name of the safe.
        name: String,
        /// The URL of the safe's logo.
        logo_url: Option<Url>,
        /// A brief description of the safe.
        description: Option<String>,
        /// The timestamp when the safe was created.
        created_at_ms: u64
    }

    const MAX_EXECUTION_DELAY_MS: u64 = 3 * 24 * 60 * 60 * 1000; // 3 days

    const EOwnersCannotBeEmpty: u64 = 0;
    const EThresholdOutOfRange: u64 = 1;
    const ESenderNotInOwners: u64 = 2;
    const EAlreadySafeOwner: u64 = 3;
    const ENotSafeOwner: u64 = 4;
    const EExecutionDelayOutOfRange: u64 = 5;
    const EInvalidOwnerCap: u64 = 6;
    const EInvalidTransactionOffset: u64 = 7;

    // ===== Public functions =====

    public fun new(name: String, description: Option<String>, logo_url: Option<ascii::String>, threshold: u64, owners: vector<address>, clock: &Clock, ctx: &mut TxContext): Safe {
        assert!(!owners.is_empty(), EOwnersCannotBeEmpty);
        assert!(owners.contains(&ctx.sender()), ESenderNotInOwners);
        assert!(threshold > 0 && threshold <= owners.length(), EThresholdOutOfRange);

        let metadata = new_metadata(name, logo_url, description, clock);

        let mut safe = Safe {
            id: object::new(ctx),
            metadata,
            threshold,
            execution_delay_ms: 0,
            owners: vector::empty(),
            last_stale_transaction: 0,
            transactions: object_table::new(ctx)
        };

        let (mut i, len) = (0, owners.length());
        while (i < len) {
            let owner = owners[i];
            safe.add_owner(owner);
            i = i + 1;
        };

        safe
    }

    #[allow(lint(share_owned))]
    public fun share(self: Safe) {
        transfer::share_object(self);
    }

    public fun update_name(self: &mut Safe, name: String, ctx: &mut TxContext) {
        self.assert_sender_owner(ctx);
        self.metadata.name = name;
    }

    public fun update_description(self: &mut Safe, description: String, ctx: &mut TxContext) {
        self.assert_sender_owner(ctx);
        self.metadata.description = option::some(description);
    }

    public fun update_logo_url(self: &mut Safe, logo_url: ascii::String, ctx: &mut TxContext) {
        self.assert_sender_owner(ctx);
        self.metadata.logo_url = option::some(url::new_unsafe(logo_url));
    }

    public fun create_transaction(self: &mut Safe, payload: vector<vector<u8>>, clock: &Clock, ctx: &mut TxContext): SecureTransaction {
        self.assert_sender_owner(ctx);
        let index = self.transactions_count();
        let transaction = transaction::new(index, self.threshold, payload, clock, ctx);
        transaction.into_secure(self.id(), self.threshold, self.cutoff(), self.last_stale_transaction(), false, false)
    }

    public fun get_secure_transaction(self: &mut Safe, index: u64, clock: &Clock, ctx: &TxContext): SecureTransaction {
        self.assert_sender_owner(ctx);

        let transaction = self.transactions.remove(index);
        let is_stale = self.is_stale_transaction(&transaction);
        let is_execution_delay_expired = self.is_execution_delay_expired(&transaction, clock);
        transaction.into_secure(self.id(), self.threshold, self.cutoff(), self.last_stale_transaction(), is_stale, is_execution_delay_expired)
    }

    public fun return_secure_transaction(self: &mut Safe, secure: SecureTransaction) {
        let transaction = secure.into_inner();
        self.transactions.add(transaction.index(), transaction);
    }

    // ===== Internal functions =====
    fun new_metadata(name: String, logo_url: Option<ascii::String>, description: Option<String>, clock: &Clock): SafeMetadata {
        let logo_url = if(logo_url.is_some()) {
            option::some(url::new_unsafe(logo_url.destroy_some()))
        } else {
            option::none()
        };

        SafeMetadata {
            name,
            logo_url,
            description,
            created_at_ms: clock.timestamp_ms()
        }
    }

    // ===== Package functions =====

    public(package) fun add_owner(self: &mut Safe, owner: address) {
        assert!(!self.is_owner(&owner), EAlreadySafeOwner);
        self.owners.push_back(owner);
    }

    public(package) fun remove_owner(self: &mut Safe, owner: address) {
        let (exists_, index) = self.owners.index_of(&owner);
        assert!(exists_, ENotSafeOwner);
        self.owners.remove(index);

        if (self.threshold > self.owners.length()) {
            self.threshold = self.owners.length();
        }
    }

    public(package) fun set_threshold(self: &mut Safe, threshold: u64) {
        assert!(threshold > 0 && threshold <= self.owners.length(), EThresholdOutOfRange);
        self.threshold = threshold;
    }

    public(package) fun set_execution_delay_ms(self: &mut Safe, execution_delay_ms: u64) {
        assert!(execution_delay_ms <= MAX_EXECUTION_DELAY_MS, EExecutionDelayOutOfRange);
        self.execution_delay_ms = execution_delay_ms;
    }

    public(package) fun set_last_stale_transaction(self: &mut Safe, sequence_number: u64) {
        self.last_stale_transaction = sequence_number;
    }

    public(package) fun uid_mut_inner(self: &mut Safe): &mut UID {
        &mut self.id
    }

    public(package) fun uid_inner(self: &Safe): &UID {
        &self.id
    }

    // ===== getter functions =====

    public fun id(self: &Safe): ID {
        object::id(self)
    }

    public fun name(metadata: &SafeMetadata): String {
        metadata.name
    }

    public fun description(metadata: &SafeMetadata): Option<String> {
        metadata.description
    }

    public fun logo_url(metadata: &SafeMetadata): Option<Url> {
        metadata.logo_url
    }
    
    public fun threshold(self: &Safe): u64 {
        self.threshold
    }

    public fun cutoff(self: &Safe): u64 {
        (self.owners.length() - self.threshold) + 1
    }

    public fun execution_delay_ms(self: &Safe): u64 {
        self.execution_delay_ms
    }
    
    public fun transactions_count(self: &Safe): u64 {
        self.transactions.length()
    }

    public fun last_stale_transaction(self: &Safe): u64 {
        self.last_stale_transaction
    }

    public fun owners(self: &Safe): &vector<address> {
        &self.owners
    }

    public fun is_owner(self: &Safe, owner: &address): bool {
        self.owners.contains(owner)
    }

    public fun max_execution_delay_ms(): u64 {
        MAX_EXECUTION_DELAY_MS
    }

    public fun get_address(self: &Safe): address {
        self.id.to_address()
    }

    public fun is_stale_transaction(self: &Safe, transaction: &Transaction): bool {
        self.last_stale_transaction != 0 && transaction.index() <= self.last_stale_transaction
    }

    public fun is_execution_delay_expired(self: &Safe, transaction: &Transaction, clock: &Clock): bool {
        clock.timestamp_ms() >= transaction.last_status_update_ms() + self.execution_delay_ms
    }

    public fun get_transaction_ids(self: &Safe, offset: Option<u64>, limit: Option<u64>): vector<ID> {
        let transactions_count = self.transactions_count();

        let offset = offset.destroy_with_default(0);
        let limit = limit.destroy_with_default(transactions_count);
        assert!(offset <= transactions_count, EInvalidTransactionOffset);

        let end = math::min(offset + limit, transactions_count);
        let (mut i, mut transactions) = (offset, vector::empty());

        while (i < end) {
            transactions.push_back(self.transactions.borrow(i).id());
            i = i + 1;
        };

        transactions
    }

    // ===== Assertions & Validations =====

    public fun assert_sender_owner(self: &Safe, ctx: &TxContext) {
        assert!(self.owners.contains(&ctx.sender()), EInvalidOwnerCap);
    }
}
