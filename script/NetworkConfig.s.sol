// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/// @title NetworkConfig
/// @notice Chain-aware SuperRare contract addresses for Foundry scripts.
/// @dev Source: Confluence "Smart Contracts - Directory". Empty or N/A cells are address(0).
library NetworkConfig {
  uint256 internal constant ETHEREUM_MAINNET = 1;
  uint256 internal constant ETHEREUM_SEPOLIA = 11155111;
  uint256 internal constant BASE_MAINNET = 8453;
  uint256 internal constant BASE_SEPOLIA = 84532;

  error UnsupportedChain(uint256 chainId);

  struct Addresses {
    address superRareV1;
    address superRareV2;
    address marketplace;
    address auctionHouse;
    address marketplaceWalletV1Token;
    address creatorRegistry;
    address marketplaceSettingsV3;
    address marketplaceSettingsV2;
    address marketplaceSettingsV1;
    address sovereignSeriesFactorySpecialCreator;
    address sovereignSeriesFactory;
    address seriesNftTemplate;
    address rareClaim;
    address royaltyRegistry;
    address bazaar;
    address bazaarMarketplace;
    address bazaarAuctionHouse;
    address spaceOperatorRegistry;
    address payments;
    address collectorRoyaltiesClaim;
    address rareProxyAdmin;
    address rareGovToken;
    address rareImplementation;
    address spaceFactory;
    address spaceNftTemplate;
    address superRareAdmin;
    address approvedTokenRegistry;
    address rarePassNft;
    address ethRareFaucet;
    address stakingRegistry;
    address rewardAccumulatorFactory;
    address rarityPoolFactory;
    address lazySovereignFactory;
    address rareMinterLogic;
    address rareMinter;
    address baseL1BridgeProxy;
    address baseL1BridgeImplementation;
    address baseL2BridgeProxy;
    address baseL2BridgeImplementation;
    address rareGovTokenL2Proxy;
    address ccipReceiverL2;
    address batchOfferCreatorImplementation;
    address batchOfferCreatorProxy;
    address season2Claim;
    address season1Claim;
    address season3Claim;
    address marketUtilsV2;
    address erc20ApprovalManager;
    address erc721ApprovalManager;
    address erc1155ApprovalManager;
    address rareErc1155TradeExecutionModule;
    address rareErc1155CheckoutExecutionModule;
    address rareErc1155MarketplaceImplementation;
    address rareErc1155MarketplaceProxy;
    address rareErc1155ContractFactory;
    address rareErc1155Implementation;
    address rareErc1155ContractFactoryOwner;
    address rareErc1155ContractFactoryDefaultMinter;
    address approvalManagerAdmin;
    address rareBatchAuctionHouseProxy;
    address rareBatchAuctionHouseLogic;
    address rareBatchListingMarketplaceImplementation;
    address rareBatchListingMarketplaceProxy;
    address rareStakingV1;
    address rareStakingV1Implementation;
    address sovereignBatchMintFactory;
    address sovereignBatchMintImplementation;
    address batchAuctionHouse;
    address royaltyEngineManifold;
    address lazySovereignBatchMintFactory;
    address superRareBazaarErc20BuyProxy;
    address liquidFactory;
    address liquidRouter;
    address liquidRegistry;
    address rareBurner;
    address networkBeneficiary;
  }

  function getCurrent() internal view returns (Addresses memory) {
    return get(block.chainid);
  }

  function get(uint256 chainId) internal pure returns (Addresses memory config) {
    if (chainId == ETHEREUM_MAINNET) return _ethereumMainnet();
    if (chainId == ETHEREUM_SEPOLIA) return _ethereumSepolia();
    if (chainId == BASE_MAINNET) return _baseMainnet();
    if (chainId == BASE_SEPOLIA) return _baseSepolia();

    revert UnsupportedChain(chainId);
  }

  function chainName(uint256 chainId) internal pure returns (string memory) {
    if (chainId == ETHEREUM_MAINNET) return "Ethereum Mainnet";
    if (chainId == ETHEREUM_SEPOLIA) return "Ethereum Sepolia";
    if (chainId == BASE_MAINNET) return "Base Mainnet";
    if (chainId == BASE_SEPOLIA) return "Base Sepolia";

    revert UnsupportedChain(chainId);
  }

  function _ethereumMainnet() private pure returns (Addresses memory config) {
    config.superRareV1 = _addr(0x41A322b28D0fF354040e2CbC676F0320d8c8850d);
    config.superRareV2 = _addr(0xb932a70A57673d89f4acfFBE830E8ed7f75Fb9e0);
    config.marketplace = _addr(0x65B49f7AEE40347f5A90b714be4eF086f3fe5E2C);
    config.auctionHouse = _addr(0x8c9F364bf7a56Ed058fc63Ef81c6Cf09c833e656);
    config.marketplaceWalletV1Token = _addr(0x859C43DDbC6aD28b1eefb40d1CD696d187BAE76D);
    config.creatorRegistry = _addr(0xED6Fd0e8c85BA50438f2399efCcA1c6476D04eA6);
    config.marketplaceSettingsV3 = _addr(0x61DBF87164d33FD3695256DC8Ba74D3B1d304170);
    config.marketplaceSettingsV2 = _addr(0xec882716989e12C31e72C8A48924941D2bA5284E);
    config.marketplaceSettingsV1 = _addr(0x1634c3b0b39da13f8724361bdF295b607767B456);
    config.sovereignSeriesFactorySpecialCreator = _addr(0x8B0a05d8FCEA149dC2d215342b233962dcc63483);
    config.sovereignSeriesFactory = _addr(0xE980EC62378529D95Ba446433F4DEB6324129c59);
    config.seriesNftTemplate = _addr(0xD89201E874DD35C9a7e80630ea98cE2595eAaa45);
    config.rareClaim = _addr(0x5474b3abF3E58A2b32F329F3633406a0d2941E6F);
    config.royaltyRegistry = _addr(0x17B0C8564E53f22364A6C8de6F7ca5CE9BEa4e5D);
    config.bazaar = _addr(0x6D7c44773C52D396F43c2D511B81aa168E9a7a42);
    config.bazaarMarketplace = _addr(0x39C36E6E02e7CC0079988C6731D54cF40fc53490);
    config.bazaarAuctionHouse = _addr(0x762e0C294dEc7f17e632f6A50DC3386F81Fc13d6);
    config.spaceOperatorRegistry = _addr(0x18C4545274721940985e93b1991CC651B1A41a8b);
    config.payments = _addr(0xc033BBef0Af25Db7523FCe16BaB1C39df0bF2Ae3);
    config.collectorRoyaltiesClaim = _addr(0xb661241653B0174e3d758CeE01e320A1f4BcAeBF);
    config.rareProxyAdmin = _addr(0x714C85F8de8632FaC4042C06B95329b9E78AeDB5);
    config.rareGovToken = _addr(0xba5BDe662c17e2aDFF1075610382B9B691296350);
    config.spaceFactory = _addr(0x3B2d699110aa1788B2B1cae336E0bA8ff942A390);
    config.spaceNftTemplate = _addr(0x093Ebc9D65E990Ab6D615b761ceaDAC026c865e5);
    config.superRareAdmin = _addr(0x186FbE119aC87c65B9cfA9Da07bEc216FA35E6cE);
    config.approvedTokenRegistry = _addr(0x16c9e9Bc7fD73F538e7dFc2eb1A21F429C3e0B8C);
    config.rarePassNft = _addr(0xbbb62C4B8ed027530Ce5F6663D1A2aa8a7E8CaCF);
    config.stakingRegistry = _addr(0x0c891cBA9A617e6B06c9B6FBBD340d61e4Dd313b);
    config.rewardAccumulatorFactory = _addr(0x7Eeb592e65d7f977717ece8f087dBD931F3b21C5);
    config.rarityPoolFactory = _addr(0x5d09145E1E798c7a885e49a6FC4f0542ce231A47);
    config.lazySovereignFactory = _addr(0xba798BD606d86D207ca2751510173532899117a1);
    config.rareMinterLogic = _addr(0xf4E4ADf2F91b8951e7B0fB218152d743B680b636);
    config.rareMinter = _addr(0x5fa112EFeD8297bec0010b312208d223E0cE891E);
    config.baseL1BridgeProxy = _addr(0x88135DD0e7a8a2e42272DdA89849a997CE2e83f7);
    config.baseL1BridgeImplementation = _addr(0x137De26EAc8ac7D32a29d6C90400EA5A0dA3aE59);
    config.batchOfferCreatorImplementation = _addr(0xfb5d0E8b2fEFC64971A075BeD08011Ac38876E7D);
    config.batchOfferCreatorProxy = _addr(0xE15CF80b25272ade261532EfDB7912F9104851d4);
    config.season1Claim = _addr(0x65B852E084d4b7B3a3ab202541aF3bc5E7b2af03);
    config.erc20ApprovalManager = _addr(0xa837a7eAff154Ab837617Cf7250648D3Ec0A4436);
    config.erc721ApprovalManager = _addr(0x4bb0Deea6d1A30C601338aAB776d394C2AE5c0F8);
    config.erc1155ApprovalManager = address(0);
    config.approvalManagerAdmin = _addr(0xdc005449848f65639D101A7D2B141c527E53f9d4);
    config.rareBatchAuctionHouseProxy = _addr(0xdfce0a0569492c59f27B3715b81F1Bd25DdEbcE3);
    config.rareBatchAuctionHouseLogic = _addr(0xED45D28be67A99Fa83194Ed9568712775688b18C);
    config.rareBatchListingMarketplaceImplementation = _addr(0xE46Eab414D5aF20C18DfE3d276973D28126ceeAC);
    config.rareBatchListingMarketplaceProxy = _addr(0x6a190885A806D39A0A8C348bfA1ac762D72E608d);
    config.rareStakingV1 = _addr(0x3f4D749675B3e48bCCd932033808a7079328Eb48);
    config.rareStakingV1Implementation = _addr(0xFCAA7FbB6F6Bf16aA546fE81261F590288FC21A1);
    config.sovereignBatchMintFactory = _addr(0xAe8E375a268Ed6442bEaC66C6254d6De5AeD4aB1);
    config.sovereignBatchMintImplementation = _addr(0x8FDEEd0d2A66277131003F686Dab90eDaBF3EA51);
    config.batchAuctionHouse = _addr(0xdfce0a0569492c59f27B3715b81F1Bd25DdEbcE3);
    config.royaltyEngineManifold = _addr(0x0385603ab55642cb4Dd5De3aE9e306809991804f);
    config.lazySovereignBatchMintFactory = _addr(0x40F9E4b420D5A8fF5aED32B5F72A37013c0739B6);
    config.superRareBazaarErc20BuyProxy = _addr(0x9d7f4fbe053Fc5029AC17E67d6138980D6212Fa5);
    config.liquidFactory = _addr(0x25f993C222fE5e891128a782A5168f1C78629540);
    config.liquidRouter = _addr(0xEBd58EdA8408d9EA409f2c2bE8898BD9738f3583);
    config.liquidRegistry = _addr(0x4066052d6AAC25EcFB027fD0C1aD54A597Ce3A31);
    config.rareBurner = _addr(0x64F366E6d515dA78930B8b37c858c67e357b7B5B);
    config.networkBeneficiary = _addr(0x860a80d33E85e97888F1f0C75c6e5BBD60b48DA9);

    // Missing from directory.
    config.rareImplementation = address(0);
    config.ethRareFaucet = address(0);
    config.baseL2BridgeProxy = address(0);
    config.baseL2BridgeImplementation = address(0);
    config.rareGovTokenL2Proxy = address(0);
    config.ccipReceiverL2 = address(0);
    config.season2Claim = address(0);
    config.season3Claim = address(0);
    config.marketUtilsV2 = address(0);
  }

  function _ethereumSepolia() private pure returns (Addresses memory config) {
    config.superRareV1 = _addr(0x4eb420094a17f243878896e274D67A04F916C214);
    config.superRareV2 = _addr(0x6C7C4879dd37Bdf2B57f128b344DeF62DA0Ca34e);
    config.creatorRegistry = _addr(0x38302C717F793dD7EA5C0a2F215494409EaD3ce0);
    config.marketplaceSettingsV3 = _addr(0x972dEe8fa339ad2D9c6cbDA31b67f98Fac242d13);
    config.marketplaceSettingsV2 = _addr(0x19aaBde5B3d83705EA294fC1aE0E2463Aa9b16Cd);
    config.marketplaceSettingsV1 = _addr(0x410995DdEC253124a10BDf651FC4c3313d7F7bd8);
    config.sovereignSeriesFactorySpecialCreator = _addr(0xce719c6C4aCac81c6052Fb2A6723B7e4209a7992);
    config.sovereignSeriesFactory = _addr(0x097Fbc68C9FBbEbA75E64337beC9759F10C9f3B6);
    config.royaltyRegistry = _addr(0xca491bb62A7730E97F500510132C47633DDD0229);
    config.bazaar = _addr(0xC8Edc7049b233641ad3723D6C60019D1c8771612);
    config.bazaarMarketplace = _addr(0xA6c7462d370930052D5c71644BEbCA26C505BC67);
    config.bazaarAuctionHouse = _addr(0xE2A332f875683793f7005c89a3742ec55557FF3c);
    config.spaceOperatorRegistry = _addr(0x31fF6869aCfFa4179Ce1BDF097Cf3EdF7C1F7AD0);
    config.payments = _addr(0x4aD440013C5B6aD09D03A3FE26DA8EcFaFc17067);
    config.rareGovToken = _addr(0x197FaeF3f59eC80113e773Bb6206a17d183F97CB);
    config.rareImplementation = _addr(0xfF0D5A1ce9166f4d530928Db305c46F843622061);
    config.spaceFactory = _addr(0x8b21bC8571d11F7AdB705ad8F6f6BD1deb79cE01);
    config.approvedTokenRegistry = _addr(0x297d05Dc747E993D8Ded20529CFFb7cA46793123);
    config.ethRareFaucet = _addr(0xb4F321B1623bB1D4DfedEB3B28288d12AEeE6640);
    config.stakingRegistry = _addr(0x18764BEA22e63e7F58D3cF454D94e279bA0f3F3C);
    config.rewardAccumulatorFactory = _addr(0xdD0aDcd77Df006c5De1EeF37478c21f12010549A);
    config.rarityPoolFactory = _addr(0x2ddDee42069B66A290c2979D62eb498692492eD9);
    config.lazySovereignFactory = _addr(0xc5B8Ad9003673a23d005A6448C74d8955a1a38fA);
    config.rareMinterLogic = _addr(0xf9711adb01570eac30467007B3bBf9817A3B4632);
    config.rareMinter = _addr(0xd28Dc0B89104d7BBd902F338a0193fF063617ccE);
    config.baseL1BridgeProxy = _addr(0xdC168291658f6C5F1D0b33E573c4d289DCA9dD08);
    config.baseL1BridgeImplementation = _addr(0xdE164B8921da366bA57673e74C7De76f7C42b8f8);
    config.batchOfferCreatorImplementation = _addr(0x933394bADE88fFdb1815E22c7Bf0Dc943aC9B404);
    config.batchOfferCreatorProxy = _addr(0x371CCA54eF859bB0C7b910581a528Ee47773fd56);
    config.season1Claim = _addr(0xEEfE348b0d5ECD0D14336dB80e83aBbA32e7EAF6);
    config.marketUtilsV2 = _addr(0xD159af05670A6A5bBaB9e086717667C75351Ba3e);
    config.erc20ApprovalManager = _addr(0x4619eB29e84392CE91C27FC936A5c94d1D14b93f);
    config.erc721ApprovalManager = _addr(0x5fa0a461d3a2Ea3bFDf03e8BD37CAbB4ae84205E);
    config.erc1155ApprovalManager = _addr(0x6Fe80fd6Dba387D757729853d20B5E3fb77dF6f6);
    config.rareErc1155TradeExecutionModule = _addr(0xC0E10eB14a6049ff7c2526F328850A9692c1780C);
    config.rareErc1155CheckoutExecutionModule = _addr(0x32bfa0038618B9b182e0E468cAe8eAE45D5e77A5);
    config.rareErc1155MarketplaceImplementation = _addr(0x396edB49c290e159168d8d4d1262D3DC8027213a);
    config.rareErc1155MarketplaceProxy = _addr(0x8416851Cc48901E5dDfC7A75Faf015F06C166d51);
    config.rareErc1155ContractFactory = _addr(0x1c6468dBf0BD8C56226cD4ADa70850bB5329FF18);
    config.rareErc1155Implementation = _addr(0xC46c6e978E504AFe258E7Dec26cf84145157BA70);
    config.rareErc1155ContractFactoryOwner = _addr(0x3B9C3C5EA16E7d3c9C0bb293a549aFa4066dc162);
    config.rareErc1155ContractFactoryDefaultMinter = _addr(0x8416851Cc48901E5dDfC7A75Faf015F06C166d51);
    config.approvalManagerAdmin = _addr(0x3B9C3C5EA16E7d3c9C0bb293a549aFa4066dc162);
    config.rareBatchAuctionHouseProxy = _addr(0x293AE7701A7830B1d38A7608EdF86A106d9E2645);
    config.rareBatchAuctionHouseLogic = _addr(0xc0D9CB069d7CfFb963A1527968bF28370A978BB6);
    config.rareBatchListingMarketplaceImplementation = _addr(0xBF36590B433d22C5D69C37BE0C5E3Dfc178EdDfc);
    config.rareBatchListingMarketplaceProxy = _addr(0xF2bE72d4343beD375Cb6d0E799a3c003163860e0);
    config.sovereignBatchMintFactory = _addr(0x3c7526A0975156299CeEF369B8fF3c01cc670523);
    config.sovereignBatchMintImplementation = _addr(0xB9530FbA6cA19990E0E838D47c5AF0e4396A386e);
    config.royaltyEngineManifold = _addr(0xEF770dFb6D5620977213f55f99bfd781D04BBE15);
    config.lazySovereignBatchMintFactory = _addr(0xE5efBA88D556aDA98124654fE505465b8d494858);
    config.superRareBazaarErc20BuyProxy = _addr(0xC68D3f1D951DEb15c384E6534d82fb4dd9e87717);
    config.liquidFactory = _addr(0xb1777091C953fa2aC1fD67f2b3e2f61343F5Ce5e);
    config.liquidRouter = _addr(0x429c3Ee66E7f6CDA12C5BadE4104aF3277aA2305);
    config.liquidRegistry = _addr(0x979C2FB02B8cF352eBeD15872B76b8bE78B64Ebc);
    config.rareBurner = _addr(0x9F9c2FBC75bbea5792250374527D701332DAB4a6);
    config.networkBeneficiary = _addr(0x3B9C3C5EA16E7d3c9C0bb293a549aFa4066dc162);

    // Missing from directory.
    config.marketplace = address(0);
    config.auctionHouse = address(0);
    config.marketplaceWalletV1Token = address(0);
    config.seriesNftTemplate = address(0);
    config.rareClaim = address(0);
    config.collectorRoyaltiesClaim = address(0);
    config.rareProxyAdmin = address(0);
    config.spaceNftTemplate = address(0);
    config.superRareAdmin = address(0);
    config.rarePassNft = address(0);
    config.baseL2BridgeProxy = address(0);
    config.baseL2BridgeImplementation = address(0);
    config.rareGovTokenL2Proxy = address(0);
    config.ccipReceiverL2 = address(0);
    config.season2Claim = address(0);
    config.season3Claim = address(0);
    config.rareStakingV1 = address(0);
    config.rareStakingV1Implementation = address(0);
    config.batchAuctionHouse = address(0);
  }

  function _baseMainnet() private pure returns (Addresses memory config) {
    config.marketplaceSettingsV3 = _addr(0x1Ca04105730EF2bBE93040Feb20aCc668292F69D);
    config.marketplaceSettingsV2 = _addr(0xDDAB7C8a64eBb9E1736c2EFFA1399b43601527C0);
    config.marketplaceSettingsV1 = _addr(0xb8BEA146470829F5ad4029D27338BDE7124c6704);
    config.bazaar = _addr(0x51c36FFB05e17ed80Ee5C02fa83D7677C5613De2);
    config.bazaarMarketplace = _addr(0x9C08cB5eff936183174d7A3D4571488aa74FB18D);
    config.bazaarAuctionHouse = _addr(0x8Ea45f64b9D0c16D5704d16877F2dd93C6978C0E);
    config.payments = _addr(0x276F25fF0873cb8B5322221264aF8bD631487952);
    config.rareGovToken = _addr(0x691077C8e8de54EA84eFd454630439F99bd8C92f);
    config.rareImplementation = _addr(0x65B852E084d4b7B3a3ab202541aF3bc5E7b2af03);
    config.approvedTokenRegistry = _addr(0x23Ee5A62726a17c9594F19B893aDd0BF89dB6075);
    config.baseL2BridgeProxy = _addr(0x3b41e21094611D152a08d3691a70837F1A077dAE);
    config.baseL2BridgeImplementation = _addr(0x577A151b12294B83E99E44464e67c69ca06864BE);
    config.rareGovTokenL2Proxy = _addr(0x691077C8e8de54EA84eFd454630439F99bd8C92f);
    config.season2Claim = _addr(0xab90E329d2a8b0497e1acF3F00D682B74D6Fb33F);
    config.season3Claim = _addr(0x6F7CB9334F7b73508d7031B5268f8B6321F2bCF7);
    config.sovereignBatchMintFactory = _addr(0xf776204233Bfb52bA0dDfF24810CbDbf3DBf94dd);
    config.sovereignBatchMintImplementation = _addr(0x963427D84540A5B53b2cbD08c82533E3E963aCd4);
    config.royaltyEngineManifold = _addr(0xEF770dFb6D5620977213f55f99bfd781D04BBE15);
    config.liquidFactory = _addr(0x54016106A92895a38E54cA286216416750e517b1);
    config.liquidRouter = _addr(0x6d078A410ee2AD08cACD8d22b486365433e98b7b);
    config.liquidRegistry = _addr(0x539e8261e18C56D801c7549fb29d06c779ef5004);
    config.rareBurner = _addr(0x8B333c7cE380A7efE110Ea444e81609DBA4b75e5);
    config.networkBeneficiary = _addr(0xD2437c0511906085CbDD06C27e8915d715dC3290);

    // Missing from directory.
    config.superRareV1 = address(0);
    config.superRareV2 = address(0);
    config.marketplace = address(0);
    config.auctionHouse = address(0);
    config.marketplaceWalletV1Token = address(0);
    config.creatorRegistry = address(0);
    config.sovereignSeriesFactorySpecialCreator = address(0);
    config.sovereignSeriesFactory = address(0);
    config.seriesNftTemplate = address(0);
    config.rareClaim = address(0);
    config.royaltyRegistry = address(0);
    config.spaceOperatorRegistry = address(0);
    config.collectorRoyaltiesClaim = address(0);
    config.rareProxyAdmin = address(0);
    config.spaceFactory = address(0);
    config.spaceNftTemplate = address(0);
    config.superRareAdmin = address(0);
    config.rarePassNft = address(0);
    config.ethRareFaucet = address(0);
    config.stakingRegistry = address(0);
    config.rewardAccumulatorFactory = address(0);
    config.rarityPoolFactory = address(0);
    config.lazySovereignFactory = address(0);
    config.rareMinterLogic = address(0);
    config.rareMinter = address(0);
    config.baseL1BridgeProxy = address(0);
    config.baseL1BridgeImplementation = address(0);
    config.ccipReceiverL2 = address(0);
    config.batchOfferCreatorImplementation = address(0);
    config.batchOfferCreatorProxy = address(0);
    config.season1Claim = address(0);
    config.marketUtilsV2 = address(0);
    config.erc20ApprovalManager = address(0);
    config.erc721ApprovalManager = address(0);
    config.rareBatchAuctionHouseProxy = address(0);
    config.rareBatchAuctionHouseLogic = address(0);
    config.rareBatchListingMarketplaceImplementation = address(0);
    config.rareBatchListingMarketplaceProxy = address(0);
    config.rareStakingV1 = address(0);
    config.rareStakingV1Implementation = address(0);
    config.batchAuctionHouse = address(0);
    config.lazySovereignBatchMintFactory = address(0);
    config.superRareBazaarErc20BuyProxy = address(0);
  }

  function _baseSepolia() private pure returns (Addresses memory config) {
    config.creatorRegistry = _addr(0x74797488D1000d08B1f364d0989c011a86165CC1);
    config.marketplaceSettingsV3 = _addr(0xC83551914aB8784B4D779794cD74d12Ac4dF26Bc);
    config.marketplaceSettingsV2 = _addr(0x560f1Bd4B1b704073eDcEe6C1f930AC4E3AE6811);
    config.marketplaceSettingsV1 = _addr(0x7cee969e4FCB21AD3ba3e3AE49168E7189eCF2b4);
    config.sovereignSeriesFactory = _addr(0xDA805c4f6A1Af4495e6974f303Fce9d77546e804);
    config.royaltyRegistry = _addr(0xBdB00e1C5B63b3382aD51857432377d982e51AE5);
    config.bazaar = _addr(0x1f0c946F0EE87ACb268D50ede6C9B4D010AF65D2);
    config.bazaarMarketplace = _addr(0xDBC12C846F1079c4B4fD0976A2A1c1231d26E525);
    config.bazaarAuctionHouse = _addr(0xE7962f6F6A9D66682040A61E81eC711A7160d55A);
    config.spaceOperatorRegistry = _addr(0xcDC46F9Dc5Ea3619F37f9e6cF000eb8c8006EB48);
    config.payments = _addr(0xCe898D2308cEB524299C4657e63CBB720d07Ff7C);
    config.rareGovToken = _addr(0x8b21bC8571d11F7AdB705ad8F6f6BD1deb79cE01);
    config.approvedTokenRegistry = _addr(0x0eF69420ff32aB9c6D948eAc2fa88f3E67D0D239);
    config.baseL2BridgeProxy = _addr(0xca491bb62A7730E97F500510132C47633DDD0229);
    config.baseL2BridgeImplementation = _addr(0x38302C717F793dD7EA5C0a2F215494409EaD3ce0);
    config.rareGovTokenL2Proxy = _addr(0x8b21bC8571d11F7AdB705ad8F6f6BD1deb79cE01);
    config.ccipReceiverL2 = _addr(0x2B70a05320cB069e0fB55084D402343F832556E7);
    config.season2Claim = _addr(0x2A2d4Aa38afc2E48D89EbE9b57820277fBca7F2e);
    config.rareStakingV1 = _addr(0x510790DA86cc1a818b517108E4B2855458d62dE6);
    config.sovereignBatchMintFactory = _addr(0x2b181AE0f1AEA6FEd75591B04991B1A3F9868D51);
    config.sovereignBatchMintImplementation = _addr(0x1aA72D8CD9295b4A4868F98E57Da989daf081f14);
    config.royaltyEngineManifold = _addr(0x62e4a1458FA509B100F4614721Bb8463B5cC2D06);
    config.liquidFactory = _addr(0x912ecC55445d87149d09d83426D0aC41379bB643);
    config.liquidRouter = _addr(0x92438008608949E2C7eCef34c474792bAFe8a971);
    config.liquidRegistry = _addr(0x5AB6B3f7eBEFDA67cfc4D135718F9E34d58856b9);
    config.rareBurner = _addr(0x9156b06d9849429d5C6D32c815b56004d582e5C8);
    config.networkBeneficiary = _addr(0x3B9C3C5EA16E7d3c9C0bb293a549aFa4066dc162);

    // Missing from directory.
    config.superRareV1 = address(0);
    config.superRareV2 = address(0);
    config.marketplace = address(0);
    config.auctionHouse = address(0);
    config.marketplaceWalletV1Token = address(0);
    config.sovereignSeriesFactorySpecialCreator = address(0);
    config.seriesNftTemplate = address(0);
    config.rareClaim = address(0);
    config.collectorRoyaltiesClaim = address(0);
    config.rareProxyAdmin = address(0);
    config.rareImplementation = address(0);
    config.spaceFactory = address(0);
    config.spaceNftTemplate = address(0);
    config.superRareAdmin = address(0);
    config.rarePassNft = address(0);
    config.ethRareFaucet = address(0);
    config.stakingRegistry = address(0);
    config.rewardAccumulatorFactory = address(0);
    config.rarityPoolFactory = address(0);
    config.lazySovereignFactory = address(0);
    config.rareMinterLogic = address(0);
    config.rareMinter = address(0);
    config.baseL1BridgeProxy = address(0);
    config.baseL1BridgeImplementation = address(0);
    config.batchOfferCreatorImplementation = address(0);
    config.batchOfferCreatorProxy = address(0);
    config.season1Claim = address(0);
    config.season3Claim = address(0);
    config.marketUtilsV2 = address(0);
    config.erc20ApprovalManager = address(0);
    config.erc721ApprovalManager = address(0);
    config.rareBatchAuctionHouseProxy = address(0);
    config.rareBatchAuctionHouseLogic = address(0);
    config.rareBatchListingMarketplaceImplementation = address(0);
    config.rareBatchListingMarketplaceProxy = address(0);
    config.rareStakingV1Implementation = address(0);
    config.batchAuctionHouse = address(0);
    config.lazySovereignBatchMintFactory = address(0);
    config.superRareBazaarErc20BuyProxy = address(0);
  }

  function _addr(address raw) private pure returns (address) {
    return raw;
  }
}
