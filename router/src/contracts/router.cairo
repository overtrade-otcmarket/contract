use starknet::{ContractAddress, ClassHash};
use crate::models::match_offer::MatchOfferInfo;

#[starknet::interface]
pub trait IRouter<TContractState> {
    ////////////////////
    // Read functions //
    ////////////////////

    fn get_market_price(self: @TContractState, asset_id: felt252) -> (u128, u32);
    fn get_balance(self: @TContractState) -> u256;
    fn get_pair(
        self: @TContractState, token: ContractAddress, asset_id: felt252
    ) -> ContractAddress;
    fn get_fee(self: @TContractState) -> u256;
    fn is_promoter(self: @TContractState, address: ContractAddress) -> bool;

    /////////////////////
    // Write functions //
    /////////////////////

    fn change_pair_classhash(ref self: TContractState, new_classhash: ClassHash);
    fn change_fee(ref self: TContractState, new_fee: u256);
    fn make_offer(
        ref self: TContractState,
        asset_id: felt252,
        token: ContractAddress,
        action: bool,
        fill: bool,
        amount: u256,
        price_type: bool,
        price: u256,
        expired: u64
    ) -> u256;
    fn cancel_offer(ref self: TContractState, offer_id: u256, token: ContractAddress);
    fn match_offer(
        ref self: TContractState, offer_id: u256, token: ContractAddress, match_amount: u256
    );
    fn authenticated_match_offer(
        ref self: TContractState,
        match_offer_info: MatchOfferInfo,
        signature_s: felt252,
        signature_r: felt252
    );
    fn claim(ref self: TContractState);
    fn remove_pair(ref self: TContractState, token: ContractAddress);
}

#[starknet::interface]
pub trait IPair<TContractState> {
    ////////////////////
    // Read functions //
    ////////////////////

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
pub trait IAccount<TContractState> {
    fn supports_interface(self: @TContractState, interface_id: felt252) -> bool;
}

#[starknet::contract]
pub mod Router {
    use starknet::event::EventEmitter;
    use core::Zeroable;
    use core::result::ResultTrait;
    use core::hash::HashStateTrait;
    use core::pedersen::PedersenTrait;
    use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::{
        ContractAddress, get_contract_address, get_caller_address, get_block_timestamp,
        storage::{
            Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
            StoragePointerWriteAccess
        },
        syscalls::{call_contract_syscall, deploy_syscall},
        class_hash::{ClassHash, Felt252TryIntoClassHash}, SyscallResultTrait, SyscallResult,
    };
    use crate::components::{ownable::OwnableComponent, upgradeable::UpgradeableComponent};
    use crate::models::match_offer::{MatchOfferInfo, MatchOfferInfoTrait};
    use super::{IPairDispatcher, IPairDispatcherTrait, IAccountDispatcher, IAccountDispatcherTrait};
    use pragma_lib::{
        abi::{IPragmaABIDispatcher, IPragmaABIDispatcherTrait},
        types::{DataType, AggregationMode, PragmaPricesResponse}
    };

    component!(path: OwnableComponent, storage: OwnableStorage, event: OwnableEvent);
    component!(path: UpgradeableComponent, storage: UpgradeableStorage, event: UpgradeableEvent);
    #[abi(embed_v0)]
    impl Ownable = OwnableComponent::OwnableImpl<ContractState>;
    #[abi(embed_v0)]
    impl Upgradeable = UpgradeableComponent::UpgradeableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::OwnableInternalImpl<ContractState>;


    pub mod Error {
        pub const NOT_PAIR: felt252 = 'Not pair';
        pub const PAIR_NOT_EXIST: felt252 = 'Pair does not exist';
        pub const INVALID_CLASS: felt252 = 'Invalid class';
        pub const PROTOCOL_NOT_SUPPORTED: felt252 = 'Protocol not supported';
        pub const INVALID_SIGNATURE: felt252 = 'Invalid signature';
    }

    pub mod PRICE_TYPE {
        pub const FIXED: bool = false;
        pub const MARKET: bool = true;
    }

    #[storage]
    struct Storage {
        fee: u256,
        total_order: u256,
        pair_classhash: ClassHash,
        pair: Map<ContractAddress, ContractAddress>,
        asset_id: Map<ContractAddress, felt252>,
        is_pair: Map<ContractAddress, bool>,
        nonce: Map<u256, bool>,
        #[substorage(v0)]
        OwnableStorage: OwnableComponent::Storage,
        #[substorage(v0)]
        UpgradeableStorage: UpgradeableComponent::Storage
    }

    #[derive(Drop, starknet::Event)]
    pub struct PairCreatedEvent {
        pair: ContractAddress,
        token: ContractAddress,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct OfferCreatedEvent {
        offer_id: u256,
        asset_id: felt252,
        token: ContractAddress,
        offeror: ContractAddress,
        action: bool,
        fill: bool,
        amount: u256,
        price_type: bool,
        price: u256,
        expired: u64,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct FillOfferEvent {
        offer_id: u256,
        token: ContractAddress,
        offerer: ContractAddress,
        amount: u256,
        remaining: u256,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct OfferCancelledEvent {
        offer_id: u256,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PairClasshashUpgradedEvent {
        classhash: ClassHash,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        PairCreatedEvent: PairCreatedEvent,
        OfferCreatedEvent: OfferCreatedEvent,
        FillOfferEvent: FillOfferEvent,
        OfferCancelledEvent: OfferCancelledEvent,
        PairClasshashUpgradedEvent: PairClasshashUpgradedEvent,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event
    }

    #[derive(Drop, PartialEq, Serde)]
    struct GetSignersResponse {
        stark: Array<felt252>,
        secp256r1: Array<felt252>,
        webauthn: Array<felt252>,
    }

    const OWNER_ADDRESS: felt252 =
        0x0160CF0a8cE336b6551e6E56Bb89a8280DEEA5956e54B578e13B753eD8a8a1B5;
    const DEV_ADDRESS: felt252 = 0x01ad504c5E1958b19B3A1d2e24A03Bc2Eb24daa19eee1ddf9a8db9d1FCD4E00c;
    const PAIR_CLASSHASH: felt252 =
        0x00756a2d86b5776e52846b2e07a94aa25172b51ae2a2d66c7d44d2bd6cf6b1fa;
    pub const NATIVE_TOKEN_CONTRACT_ADDRESS: felt252 =
        0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d;
    pub const PRAGMA_CONTRACT_ADDRESS: felt252 =
        0x2a85bd616f912537c50a49a4076db02c00b29b2cdc8a197ce92ed1837fa875b;

    pub const DECIMAL: u256 = 1_000_000_000_000_000_000;

    #[constructor]
    fn constructor(ref self: ContractState) {
        self
            .OwnableStorage
            .initializer(OWNER_ADDRESS.try_into().unwrap(), DEV_ADDRESS.try_into().unwrap());
        self.fee.write(10);
        self.pair_classhash.write(PAIR_CLASSHASH.try_into().unwrap());
    }

    #[abi(embed_v0)]
    impl IRouterImpl of super::IRouter<ContractState> {
        ////////////////////
        // Read functions //
        ////////////////////

        fn is_promoter(self: @ContractState, address: ContractAddress) -> bool {
            // Check if the wallet is implemented 2FA
            // The wallet contract has the function `get_signers() or getSigners()`
            // Wallet is implemented 2FA if the function returns more than 1 address

            // Check if the wallet is Braavos Wallet
            let interface_id: felt252 = 0xf10dbd44;
            let is_bravoos_wallet = IAccountDispatcher {
                contract_address: address
            }
                .supports_interface(interface_id);

            // Check if the wallet is implemented 2FA
            match is_bravoos_wallet {
                true => {
                    match call_contract_syscall(address, selector!("get_signers"), (array![]).span()) {
                        Result::Ok(mut result) => {
                            let mut response_raw = Serde::<GetSignersResponse>::deserialize(ref result);
                            match response_raw {
                                Option::Some(response) => {
                                    let has_valid_signers = response.secp256r1.len() > 0 || response.webauthn.len() > 0;
                                    has_valid_signers
                                },
                                Option::None => false
                            }
                        },
                        Result::Err(_) => false,
                    }
                },
                false => false
            }
        }

        fn get_market_price(self: @ContractState, asset_id: felt252) -> (u128, u32) {
            let strk_usd: PragmaPricesResponse = IPragmaABIDispatcher {
                contract_address: PRAGMA_CONTRACT_ADDRESS.try_into().unwrap()
            }
                .get_data_median(DataType::SpotEntry('STRK/USD'));
            let asset_usd: PragmaPricesResponse = IPragmaABIDispatcher {
                contract_address: PRAGMA_CONTRACT_ADDRESS.try_into().unwrap()
            }
                .get_data_median(DataType::SpotEntry(asset_id));

            let price = asset_usd.price / strk_usd.price;

            (price, asset_usd.decimals)
        }

        fn get_pair(
            self: @ContractState, token: ContractAddress, asset_id: felt252
        ) -> ContractAddress {
            if (!self.pair.read(token).is_zero()) {
                return self.pair.read(token);
            }
            self._get_pair(token, asset_id, self.pair_classhash.read())
        }

        fn get_fee(self: @ContractState) -> u256 {
            self.fee.read()
        }

        fn get_balance(self: @ContractState) -> u256 {
            IERC20Dispatcher { contract_address: NATIVE_TOKEN_CONTRACT_ADDRESS.try_into().unwrap() }
                .balance_of(get_contract_address())
        }

        /////////////////////
        // Write functions //
        /////////////////////

        fn change_pair_classhash(ref self: ContractState, new_classhash: ClassHash) {
            self.OwnableStorage._assert_only_admin();
            assert(!new_classhash.is_zero(), Error::INVALID_CLASS);
            self.pair_classhash.write(new_classhash);
            self.emit(PairClasshashUpgradedEvent { classhash: new_classhash });
        }

        fn change_fee(ref self: ContractState, new_fee: u256) {
            self.OwnableStorage._assert_only_admin();
            self.fee.write(new_fee);
        }

        fn make_offer(
            ref self: ContractState,
            asset_id: felt252,
            token: ContractAddress,
            action: bool,
            fill: bool,
            amount: u256,
            price_type: bool,
            price: u256,
            expired: u64
        ) -> u256 {
            let offeror = get_caller_address();
            let mut pair = self.pair.read(token);
            if !pair.is_non_zero() {
                pair = self._deploy_pair(token, asset_id);
                self.pair.write(token, pair);
                self.is_pair.write(pair, true);
                self.asset_id.write(pair, asset_id);
            }
            self.total_order.write(self.total_order.read() + 1);
            let offer_id = IPairDispatcher { contract_address: pair }
                .make_offer(
                    self.total_order.read(),
                    offeror,
                    action,
                    fill,
                    amount,
                    price_type,
                    price,
                    expired
                );
            self
                .emit(
                    OfferCreatedEvent {
                        offer_id,
                        asset_id,
                        token,
                        offeror,
                        action,
                        fill,
                        amount,
                        price_type,
                        price,
                        expired,
                        timestamp: get_block_timestamp()
                    }
                );
            offer_id
        }

        fn cancel_offer(ref self: ContractState, offer_id: u256, token: ContractAddress) {
            let pair = self.pair.read(token);
            assert(pair.is_non_zero(), Error::PAIR_NOT_EXIST);
            IPairDispatcher { contract_address: pair }.cancel_offer(get_caller_address(), offer_id);
            self.emit(OfferCancelledEvent { offer_id, timestamp: get_block_timestamp() });
        }

        fn match_offer(
            ref self: ContractState, offer_id: u256, token: ContractAddress, match_amount: u256
        ) {
            let offerer = get_caller_address();
            let pair = self.pair.read(token);
            assert(pair.is_non_zero(), Error::PAIR_NOT_EXIST);

            let (_offeror, _action, _fill, amount, price_type, price, _status, _expired) =
                IPairDispatcher {
                contract_address: pair
            }
                .get_offer(offer_id);

            let match_price = if price_type == PRICE_TYPE::MARKET {
                let (market_price, _decimals) = self.get_market_price(self.asset_id.read(pair));
                assert(market_price.is_non_zero(), Error::PROTOCOL_NOT_SUPPORTED);
                (market_price.into() * price * DECIMAL / 100_u256)
            } else {
                price
            };

            let remaining = IPairDispatcher { contract_address: pair }
                .match_offer(offerer, offer_id, match_amount, match_price);

            self
                .emit(
                    FillOfferEvent {
                        offer_id,
                        token,
                        offerer,
                        amount,
                        remaining,
                        timestamp: get_block_timestamp()
                    }
                );
        }

        fn authenticated_match_offer(
            ref self: ContractState,
            match_offer_info: MatchOfferInfo,
            signature_s: felt252,
            signature_r: felt252
        ) {
            let match_offer = MatchOfferInfoTrait::verify_signature(
                match_offer_info, signature_r, signature_s
            );
            assert(!self.nonce.read(match_offer.nonce), Error::INVALID_SIGNATURE);
            self.nonce.write(match_offer.nonce, true);

            let token = match_offer.offer_token;
            let offer_id = match_offer.offer_id;
            let match_amount = match_offer.match_amount;
            let market_price = match_offer.market_price;
            let offerer = get_caller_address();
            let pair = self.pair.read(token);
            assert(pair.is_non_zero(), Error::PAIR_NOT_EXIST);

            let (_offeror, _action, _fill, _amount, price_type, price, _status, _expired) =
                IPairDispatcher {
                contract_address: pair
            }
                .get_offer(offer_id);

            let match_price = if price_type == PRICE_TYPE::MARKET {
                (market_price * price / 100_u256)
            } else {
                price
            };

            let remaining = IPairDispatcher { contract_address: pair }
                .match_offer(offerer, offer_id, match_amount, match_price);

            self
                .emit(
                    FillOfferEvent {
                        offer_id,
                        token,
                        offerer,
                        amount: match_amount,
                        remaining,
                        timestamp: get_block_timestamp()
                    }
                );
        }

        fn claim(ref self: ContractState) {
            self.OwnableStorage._assert_only_owner();
            let balance = IERC20Dispatcher {
                contract_address: NATIVE_TOKEN_CONTRACT_ADDRESS.try_into().unwrap()
            }
                .balance_of(get_contract_address());
            IERC20Dispatcher { contract_address: NATIVE_TOKEN_CONTRACT_ADDRESS.try_into().unwrap() }
                .transfer(get_caller_address(), balance);
        }

        fn remove_pair(ref self: ContractState, token: ContractAddress) {
            self.OwnableStorage._assert_only_admin();
            let pair = self.pair.read(token);
            assert(pair.is_non_zero(), Error::PAIR_NOT_EXIST);
            self.pair.write(token, Zeroable::zero());
            self.is_pair.write(pair, false);
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _deploy_pair(
            ref self: ContractState, token: ContractAddress, asset_id: felt252
        ) -> ContractAddress {
            let mut constructor_calldata: Array<felt252> = array![token.into(), asset_id,];

            let salt = PedersenTrait::new(0)
                .update(token.into())
                .update(asset_id)
                .update(get_contract_address().into())
                .update(3)
                .finalize();
            let class_hash: ClassHash = self.pair_classhash.read();
            let result = deploy_syscall(class_hash, salt, constructor_calldata.span(), true);
            let (pair_address, _) = result.unwrap_syscall();

            self
                .emit(
                    PairCreatedEvent { pair: pair_address, token, timestamp: get_block_timestamp() }
                );

            pair_address
        }

        fn _get_pair(
            self: @ContractState, token: ContractAddress, asset_id: felt252, classhash: ClassHash
        ) -> ContractAddress {
            let constructor_calldata_hash = PedersenTrait::new(0)
                .update(token.into())
                .update(asset_id)
                .update(2)
                .finalize();

            let salt = PedersenTrait::new(0)
                .update(token.into())
                .update(asset_id)
                .update(get_contract_address().into())
                .update(3)
                .finalize();

            let prefix: felt252 = 'STARKNET_CONTRACT_ADDRESS';
            let account_address = PedersenTrait::new(0)
                .update(prefix)
                .update(0)
                .update(salt)
                .update(classhash.try_into().unwrap())
                .update(constructor_calldata_hash)
                .update(5)
                .finalize();

            account_address.try_into().unwrap()
        }
    }
}
