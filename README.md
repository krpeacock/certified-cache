# HTTP Request Upgrading Example

This is an example of how to use the `upgrade = true` HTTP response to upgrade a query to an update, in conjunction with a cache for the requests. This way, a canister can upgrade to an `update` request, and then use the cache to store the request, and then use the cache to respond with future queries.

A fully fledged example in the future would also have a cache invalidation or expiration strategy, but this is just meant to highlight the API.

## Running

To run this example, you will need to have the `dfx` CLI installed. You can install it by following the instructions [here](https://internetcomputer.org/docs/current/tutorials/deploy_sample_app).

You will also need `mops` installed. You can install it by following the instructions [here](https://j4mwm-bqaaa-aaaam-qajbq-cai.ic0.app/).

Once you have `dfx` and `mops` installed, you can run the following commands:

```bash
mops install
dfx start
dfx deploy
```

This will install the dependencies, start the local network, and deploy the canister. To test the canister, you can run the following command:

```bash
curl "http://localhost:$(dfx info webserver-port)?canisterId=$(dfx canister id cache)"
```

The first time you request a fresh URL, you will get output along the lines of

```
[Canister rdmx6-jaaaa-aaaaa-aaadq-cai] Request was not found in cache. Upgrading to update request.

[Canister rdmx6-jaaaa-aaaaa-aaadq-cai] Storing request in cache.
```

Subsequently, it should look like:

```
[Canister rrkah-fqaaa-aaaaa-aaaaq-cai] Request has been stored in cache:
URL is: /?canisterId=rrkah-fqaaa-aaaaa-aaaaq-cai
Method is GET
Body is: ""
Timestamp is:
+1_678_484_003_838_524_000
```

Take this idea and run with it! I think it will be really powerful for JSON responses and other types of APIs.
