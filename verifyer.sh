#  forge verify-contract --watch --chain sepolia 0xaee7d5e08c9eE3FeAd11cD3304EF65C666880cB1 src/NFTGovernor.sol:NFTGovernor --constructor-args-path arg.txt --verifier etherscan --etherscan-api-key "$ETHERSCAN_APIKEY"




forge create --broadcast --rpc-url https://rpc.sepolia.ethpandaops.io --private-key "$PRIVATE_KEY" src/NFTGovernor.sol:NFTGovernor --constructor-args-path arg.txt  --verify --verifier etherscan --etherscan-api-key "$ETHERSCAN_APIKEY"