use starknet::ContractAddress;

#[starknet::interface]
pub trait IPair<TContractState> {
    ////////////////////
    // Read functions //
    ////////////////////

    fn get_token(self: @TContractState) -> ContractAddress;

    fn get_offer(
        self: @TContractState, offer_id: u256
    ) -> (ContractAddress, bool, bool, u256, bool, u256, bool, u64);

    /////////////////////
    // Write functions //
    /////////////////////

    fn make_offer(
        ref self: TContractState,
        offer_id: u256,
        offeror: ContractAddress,
        action: bool,
        fill: bool,
        amount: u256,
        price_type: bool,
        price: u256,
        expired: u64
    ) -> u256;
    fn cancel_offer(ref self: TContractState, offeror: ContractAddress, offer_id: u256);
    fn match_offer(
        ref self: TContractState,
        offerer: ContractAddress,
        offer_id: u256,
        amount: u256,
        price: u256
    ) -> u256;
}

#[starknet::interface]
pub trait IRouter<TContractState> {
    fn get_fee(self: @TContractState) -> u256;
    fn is_promoter(self: @TContractState, address: ContractAddress) -> bool;
}

#[starknet::contract]
pub mod Pair {
    use starknet::{
        ContractAddress, get_caller_address, get_block_timestamp, get_contract_address,
        storage::{
            Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
            StoragePointerWriteAccess
        }
    };
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use super::{IRouterDispatcher, IRouterDispatcherTrait};
    use crate::components::{ownable::OwnableComponent, upgradeable::UpgradeableComponent};

    component!(path: OwnableComponent, storage: OwnableStorage, event: OwnableEvent);
    component!(path: UpgradeableComponent, storage: UpgradeableStorage, event: UpgradeableEvent);
    #[abi(embed_v0)]
    impl Ownable = OwnableComponent::OwnableImpl<ContractState>;
    #[abi(embed_v0)]
    impl Upgradeable = UpgradeableComponent::UpgradeableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::OwnableInternalImpl<ContractState>;

    pub mod Error {
        pub const UNAUTHORIZED: felt252 = 'Unauthorized';
        pub const INVALID_OFFER_ID: felt252 = 'Invalid offer id';
        pub const INVALID_AMOUNT: felt252 = 'Invalid amount';
        pub const INVALID_FEE: felt252 = 'Invalid fee';
        pub const ALLOWANCE_NOT_ENOUGH: felt252 = 'Allowance not enough';
        pub const MATCH_SELF_ORDER: felt252 = 'Match self order';
        pub const OFFER_EXPIRED: felt252 = 'Offer expired';
        pub const PROTOCOL_NOT_SUPPORTED: felt252 = 'Protocol not supported';
    }

    pub mod ACTION {
        pub const BUY: bool = true;
        pub const SELL: bool = false;
    }

    pub mod FILL {
        pub const PARTIAL: bool = true;
        pub const FULL: bool = false;
    }

    pub mod PRICE_TYPE {
        pub const FIXED: bool = false;
        pub const MARKET: bool = true;
    }

    pub const NATIVE_TOKEN_CONTRACT_ADDRESS: felt252 =
        0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d;
    pub const PRAGMA_CONTRACT_ADDRESS: felt252 =
        0x36031daa264c24520b11d93af622c848b2499b66b41d611bac95e13cfca131a;
    pub const FEE_DECIMAL: u256 = 1_000;
    pub const DECIMAL: u256 = 1_000_000_000_000_000_000;

    #[storage]
    struct Storage {
        asset_id: felt252,
        token: ContractAddress,
        offer_book: Map<u256, (ContractAddress, bool, bool, u256, bool, u256, bool, u64)>,
        // id -> (offeror, action, fill, amount, price_type, price, status, expired)
        #[substorage(v0)]
        OwnableStorage: OwnableComponent::Storage,
        #[substorage(v0)]
        UpgradeableStorage: UpgradeableComponent::Storage
    }

    #[event]
    #[derive(Drop, PartialEq, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event
    }

    
    #[constructor]
    fn constructor(
        ref self: ContractState, token: ContractAddress, asset_id: felt252
    ) {
        let router = get_caller_address();
        self.OwnableStorage.initializer(router);
        self.token.write(token);
        self.asset_id.write(asset_id);
    }

    #[abi(embed_v0)]
    impl IPairImpl of super::IPair<ContractState> {
        ////////////////////
        // Read functions //
        ////////////////////
        
        fn get_token(self: @ContractState) -> ContractAddress {
            self.token.read()
        }

        fn get_offer(
            self: @ContractState, offer_id: u256
        ) -> (ContractAddress, bool, bool, u256, bool, u256, bool, u64) {
            self.offer_book.read(offer_id)
        }

        /////////////////////
        // Write functions //
        /////////////////////

        fn make_offer(
            ref self: ContractState,
            offer_id: u256,
            offeror: ContractAddress,
            action: bool,
            fill: bool,
            amount: u256,
            price_type: bool,
            price: u256,
            expired: u64
        ) -> u256 {
            self.OwnableStorage._assert_only_router();
            self._make_offer(offer_id, offeror, action, fill, amount, price_type, price, expired)
        }

        fn cancel_offer(ref self: ContractState, offeror: ContractAddress, offer_id: u256,) {
            self.OwnableStorage._assert_only_router();
            self._cancel_offer(offeror, offer_id)
        }

        fn match_offer(
            ref self: ContractState,
            offerer: ContractAddress,
            offer_id: u256,
            amount: u256,
            price: u256
        ) -> u256 {
            self.OwnableStorage._assert_only_router();
            self._match_offer(offerer, offer_id, amount, price)
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _make_offer(
            ref self: ContractState,
            offer_id: u256,
            offeror: ContractAddress,
            action: bool,
            fill: bool,
            amount: u256,
            price_type: bool,
            price: u256,
            expired: u64
        ) -> u256 {
            if (action == ACTION::BUY) {
                // Buy Action not support MARKET price
                assert(price_type != PRICE_TYPE::MARKET, Error::PROTOCOL_NOT_SUPPORTED);
                
                // Buy Action
                // User must transfer the amount of NATIVE_TOKEN to the contract
                // corresponding to the amount * price_per_uint
                let total_transfer = amount * price / DECIMAL;
                // Approve the contract to transfer the amount of NATIVE_TOKEN
                let allowance_by_caller = IERC20Dispatcher {
                    contract_address: NATIVE_TOKEN_CONTRACT_ADDRESS.try_into().unwrap()
                }
                    .allowance(offeror, get_contract_address());
                assert(allowance_by_caller >= total_transfer, Error::ALLOWANCE_NOT_ENOUGH);

                IERC20Dispatcher {
                    contract_address: NATIVE_TOKEN_CONTRACT_ADDRESS.try_into().unwrap()
                }
                    .transfer_from(offeror, get_contract_address(), total_transfer);
            } else {
                // Sell Action
                // User must transfer the amount of token to the contract

                // Approve the contract to transfer the amount of token
                let allowance_by_caller = IERC20Dispatcher { contract_address: self.token.read() }
                    .allowance(offeror, get_contract_address());
                assert(allowance_by_caller >= amount, Error::ALLOWANCE_NOT_ENOUGH);

                // Transfer the amount of token to the contract
                IERC20Dispatcher { contract_address: self.token.read() }
                    .transfer_from(offeror, get_contract_address(), amount);
            }
            // Write the order metadata
            self
                .offer_book
                .write(offer_id, (offeror, action, fill, amount, price_type, price, true, expired));
            offer_id
        }

        fn _cancel_offer(ref self: ContractState, offeror: ContractAddress, offer_id: u256) {
            let (_offeror, action, fill, amount, price_type, price, status, expired) = self
                .offer_book
                .read(offer_id);
            assert(_offeror == offeror, Error::UNAUTHORIZED);
            assert(status, Error::INVALID_OFFER_ID);
            if action == ACTION::BUY {
                // Buy Action
                // Contract must transfer back the amount of NATIVE_TOKEN to the user

                let total = (amount * price) / DECIMAL;

                // Transfer the amount of NATIVE_TOKEN to the user
                IERC20Dispatcher {
                    contract_address: NATIVE_TOKEN_CONTRACT_ADDRESS.try_into().unwrap()
                }
                    .transfer(offeror, total);
            } else {
                // Sell Action
                // Contract must transfer back the amount of token to the user

                // Transfer the amount of token to the user
                IERC20Dispatcher { contract_address: self.token.read() }.transfer(offeror, amount);
            }

            // Write the order status
            self
                .offer_book
                .write(
                    offer_id, (offeror, action, fill, amount, price_type, price, false, expired)
                );
        }

        fn _match_offer(
            ref self: ContractState,
            offerer: ContractAddress,
            offer_id: u256,
            match_amount: u256,
            match_price: u256
        ) -> u256 {
            // Read the offer metadata
            let (offeror, action, fill, offer_amount, price_type, price, status, expired) = self
                .offer_book
                .read(offer_id);
            assert(offeror != offerer, Error::MATCH_SELF_ORDER);
            assert(status, Error::INVALID_OFFER_ID);
            if fill == FILL::FULL {
                assert(offer_amount == match_amount, Error::INVALID_AMOUNT);
            }
            assert(match_amount <= offer_amount, Error::INVALID_AMOUNT);
            assert(expired > get_block_timestamp(), Error::OFFER_EXPIRED);

            self._match_offer_without_check(offeror, offerer, action, match_amount, match_price);
            let new_amount = offer_amount - match_amount;
            let new_status = new_amount > 0;

            // Write the order status
            self
                .offer_book
                .write(
                    offer_id,
                    (offeror, action, fill, new_amount, price_type, price, new_status, expired)
                );

            new_amount
        }

        // CAREFUL !!!
        // This function is not safe, it should be used only by the [_match_offer] function
        // This function is used to match the offer without checking
        fn _match_offer_without_check(
            ref self: ContractState,
            offeror: ContractAddress,
            offerer: ContractAddress,
            action: bool,
            amount: u256,
            price: u256,
        ) {
            if action == ACTION::BUY {
                // Match Buy Action
                // User must transfer the amount of token to the order owner
                // Contract must transfer the amount of NATIVE_TOKEN to the user
                // corresponding to the amount * price_per_uint

                // Approve the contract to transfer the amount of token
                let allowance_by_caller = IERC20Dispatcher { contract_address: self.token.read() }
                    .allowance(offerer, get_contract_address());
                assert(allowance_by_caller >= amount, Error::ALLOWANCE_NOT_ENOUGH);

                // Transfer the amount of token to the order owner
                IERC20Dispatcher { contract_address: self.token.read() }
                    .transfer_from(offerer, offeror, amount);

                // Transfer the amount of NATIVE_TOKEN from contract to the user with fee
                let total = (amount * price) / DECIMAL;
                let fee = total * get_market_fee(self.OwnableStorage.router.read(), offerer) / FEE_DECIMAL;

                IERC20Dispatcher {
                    contract_address: NATIVE_TOKEN_CONTRACT_ADDRESS.try_into().unwrap()
                }
                    .transfer(offerer, total - fee);

                if fee > 0 {
                    // Transfer fee to the router contract
                    IERC20Dispatcher {
                        contract_address: NATIVE_TOKEN_CONTRACT_ADDRESS.try_into().unwrap()
                    }
                        .transfer(self.OwnableStorage.router.read(), fee);
                }
            } else {
                // Match Sell Action
                // User must transfer the amount of NATIVE_TOKEN to the order owner
                // corresponding to the amount * price_per_uint
                // Contract must transfer the amount of token to the user

                // Approve the contract to transfer the amount of NATIVE_TOKEN
                let allowance_by_caller = IERC20Dispatcher {
                    contract_address: NATIVE_TOKEN_CONTRACT_ADDRESS.try_into().unwrap()
                }
                    .allowance(offerer, get_contract_address());
                assert(
                    allowance_by_caller >= ((amount * price) / DECIMAL), Error::ALLOWANCE_NOT_ENOUGH
                );

                let total = (amount * price) / DECIMAL;
                let fee = total * get_market_fee(self.OwnableStorage.router.read(), offeror) / FEE_DECIMAL;

                // Transfer the amount of NATIVE_TOKEN to the order owner
                IERC20Dispatcher {
                    contract_address: NATIVE_TOKEN_CONTRACT_ADDRESS.try_into().unwrap()
                }
                    .transfer_from(offerer, offeror, total - fee);

                if fee > 0 {
                    // Transfer fee to the router contract
                    IERC20Dispatcher {
                        contract_address: NATIVE_TOKEN_CONTRACT_ADDRESS.try_into().unwrap()
                    }
                        .transfer_from(offerer, self.OwnableStorage.router.read(), fee);
                }

                // Transfer the amount of token to the user
                IERC20Dispatcher { contract_address: self.token.read() }.transfer(offerer, amount);
            }
        }
    }

    fn get_market_fee(router: ContractAddress, user: ContractAddress) -> u256 {
        let router = IRouterDispatcher { contract_address: router };
        let fee = if router.is_promoter(user) {
            0
        } else {
            router.get_fee()
        };
        fee
    }
}
