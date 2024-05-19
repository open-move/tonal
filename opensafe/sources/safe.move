module opensafe::safe {
    use std::ascii;
    use std::string::String;

    use sui::vec_map::{Self, VecMap};
    use sui::transfer::Receiving;
    use sui::url::{Self, Url};
    use sui::clock::Clock;
    use sui::coin::Coin;

    use opensafe::treasury::{Self, Treasury};
    use opensafe::storage::{Self, Storage};

    public struct Safe has key {
        id: UID,
        /// The ID of the safe's treasury object.
        /// The object stores the safe's coins and objects.
        storage: ID,
        /// The ID of the safe's treasury object.
        /// The object stores the safe's coins and objects.
        treasury: ID,
        /// The minimum number of owners that must approve a transaction before it is executed.
        threshold: u64,
        /// The minimum number of milliseconds that must pass before a transaction is executed.
        execution_delay_ms: u64,
        /// The index of the last invalidated transaction.
        /// Any transaction with an index less than this is invalidated and can no longer be executed.
        invalidation_number: u64,
        /// A mapping of the safe owners to their respective `OwnerCap` IDs.
        owners: VecMap<address, ID>,
        /// Safe metadata like name, description, logo_url etc.
        metadata: SafeMetadata,
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

    public struct OwnerCap has key {
        id: UID,
        safe: ID,
        /// The number of transactions this owner has created.
        transactions_count: u64,
        /// The number of votes this owner has cast.
        votes_count: vector<u64>, // 0: approved, 1: rejected, 2: cancelled
    }

    const MAX_EXECUTION_DELAY_MS: u64 = 3 * 24 * 60 * 60 * 1000; // 3 days

    const EOwnersCannotBeEmpty: u64 = 0;
    const EThresholdOutOfRange: u64 = 1;
    const ESenderNotInOwners: u64 = 2;
    const EAlreadySafeOwner: u64 = 3;
    const ENotSafeOwner: u64 = 4;
    const EExecutionDelayOutOfRange: u64 = 5;
    const EInvalidOwnerCap: u64 = 6;
    const EVoteCountOutOfRange: u64 = 7;
    const ESafeTreasuryMismatch: u64 = 9;

    // ===== Public functions =====

    public fun new(name: String, description: Option<String>, logo_url: Option<ascii::String>, threshold: u64, owners: vector<address>, clock: &Clock, ctx: &mut TxContext): (Safe, Treasury, Storage) {
        assert!(!owners.is_empty(), EOwnersCannotBeEmpty);
        assert!(owners.contains(&ctx.sender()), ESenderNotInOwners);
        assert!(threshold > 0 && threshold <= owners.length(), EThresholdOutOfRange);

        let id = object::new(ctx);
        let inner_id = id.to_inner();

        let treasury = treasury::new(inner_id, ctx);
        let storage = storage::new(inner_id, ctx);
        let metadata = new_metadata(name, logo_url, description, clock);

        let mut safe = Safe {
            id,
            metadata,
            threshold,
            execution_delay_ms: 0,
            storage: storage.id(),
            invalidation_number: 0,
            treasury: treasury.id(),
            owners: vec_map::empty(),
        };

        let (mut i, len) = (0, owners.length());
        while (i < len) {
            let owner = owners[i];
            safe.add_owner(owner, ctx);

            i = i + 1;
        };

        (safe, treasury, storage)
    }

    #[allow(lint(share_owned))]
    public fun share(self: Safe) {
        transfer::share_object(self);
    }

    public fun receive_coin<C>(self: &mut Safe, treasury: &mut Treasury, coin: Receiving<Coin<C>>) {
        assert!(self.treasury == treasury.id(), ESafeTreasuryMismatch);
        treasury.deposit_coin(transfer::public_receive(&mut self.id, coin));
    }

    public fun receive_object<T: key + store>(self: &mut Safe, treasury: &mut Treasury, object: Receiving<T>) {
        assert!(self.treasury == treasury.id(), ESafeTreasuryMismatch);
        treasury.deposit_object(transfer::public_receive(&mut self.id, object));
    }

    public fun update_name(self: &mut Safe, name: String, owner_cap: &OwnerCap, ctx: &mut TxContext) {
        self.validate_owner_cap(owner_cap, ctx);
        self.metadata.name = name;
    }

    public fun update_description(self: &mut Safe, description: String, owner_cap: &OwnerCap, ctx: &mut TxContext) {
        self.validate_owner_cap(owner_cap, ctx);
        self.metadata.description = option::some(description);
    }

    public fun update_logo_url(self: &mut Safe, logo_url: ascii::String, owner_cap: &OwnerCap, ctx: &mut TxContext) {
        self.validate_owner_cap(owner_cap, ctx);
        self.metadata.logo_url = option::some(url::new_unsafe(logo_url));
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

    public(package) fun add_owner(self: &mut Safe, owner: address, ctx: &mut TxContext) {
        assert!(!self.is_owner(&owner), EAlreadySafeOwner);

        let owner_cap = OwnerCap { 
            id: object::new(ctx), 
            safe: self.id.to_inner(),
            transactions_count: 0,
            votes_count: vector[0, 0, 0]
        };

        self.owners.insert(owner, owner_cap.id.to_inner());
        transfer::transfer(owner_cap, owner);
    }

    public(package) fun remove_owner(self: &mut Safe, owner: address) {
        assert!(self.is_owner(&owner), ENotSafeOwner);
        self.owners.remove(&owner);

        if (self.threshold > self.owners.size()) {
            self.threshold = self.owners.size();
        }
    }

    public(package) fun set_threshold(self: &mut Safe, threshold: u64) {
        assert!(threshold > 0 && threshold <= self.owners.size(), EThresholdOutOfRange);
        self.threshold = threshold;
    }

    public(package) fun set_execution_delay_ms(self: &mut Safe, execution_delay_ms: u64) {
        assert!(execution_delay_ms <= MAX_EXECUTION_DELAY_MS, EExecutionDelayOutOfRange);
        self.execution_delay_ms = execution_delay_ms;
    }

    public(package) fun set_invalidation_number(self: &mut Safe, number: u64) {
        self.invalidation_number = number;
    }

    public(package) fun increment_vote_count(owner: &mut OwnerCap, kind: u64) {
        assert!(kind <= 2, EVoteCountOutOfRange);

        let vote = &mut owner.votes_count[kind];
        *vote = *vote + 1;
    }

    public(package) fun decrement_vote_count(owner: &mut OwnerCap, kind: u64) {
        assert!(kind <= 2, EVoteCountOutOfRange);

        let vote = &mut owner.votes_count[kind];
        *vote = *vote - 1;
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

    public fun treasury(self: &Safe): ID {
        self.treasury
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
        (self.owners.size() - self.threshold) + 1
    }

    public fun execution_delay_ms(self: &Safe): u64 {
        self.execution_delay_ms
    }

    public fun invalidation_number(self: &Safe): u64 {
        self.invalidation_number
    }

    public fun owners(self: &Safe): &VecMap<address, ID> {
        &self.owners
    }

    public fun is_owner(self: &Safe, owner: &address): bool {
        self.owners.contains(owner)
    }

    public fun max_execution_delay_ms(): u64 {
        MAX_EXECUTION_DELAY_MS
    }

    // ===== Assertions & Validations =====

    public fun validate_owner_cap(self: &Safe, owner_cap: &OwnerCap, ctx: &TxContext) {
        let owner = self.owners.try_get(&ctx.sender());
        assert!(owner.is_some(), ENotSafeOwner);
        assert!(owner_cap.id.to_inner() == owner.destroy_some(), EInvalidOwnerCap);
    }

    public fun is_valid_owner_cap(self: &Safe, owner_cap: &OwnerCap, ctx: &TxContext): bool {
        let owner = self.owners.try_get(&ctx.sender());
        owner_cap.id.to_inner() == owner.destroy_some()
    }
}
