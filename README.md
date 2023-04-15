# CertifiedCache

This is a Motoko library designed to make it simple to cache API responses. It is designed to be used with the [Internet Computer](https://internetcomputer.org/), but it could be used with any other system that supports Motoko.

## Installation

This library is available via the [mops.one](https://mops.one/) package manager. Once you have mops installed and set up in your project, run the following command:

```bash
mops add certified-cache
```

In your code, you can then import the library like so:

```rust
import CertifiedCache "mo:certified-cache";
```

## Usage

The cache will handle three responsibilities:
- Storing the key-value pair in the cache
- Certifying the values for `http_assets`
- Managing expirations for cached assets

To make this possible, during initialization, you will need to provide the following parameters:

```rust
initCapacity : Nat,
keyEq : (K, K) -> Bool,
keyHash : K -> Hash.Hash,
keyToBlob : K -> Blob,
valToBlob : V -> Blob,
timeToLive : Nat,
```

> Note - if you use the `fromEntries` constructor, you can provide the entries, rather than the `initCapacity`.

Since this is a `class` and not a stable memory structure, it is also recommended you serialize the cache to an array during upgrades. Here is an example of how this works, using a `Text` key and a `Blob` value:

```rust
import CertifiedCache "mo:certified-cache";

actor {
    stable var entries : [(Text, (Blob, Nat))] = [];
    var cache = CertifiedCache.fromEntries<Text, Blob>(
    entries,
    Text.equal,
    Text.hash,
    Text.encodeUtf8,
    func(b : Blob) : Blob { b },
    two_days_in_nanos,
  );

  // application logic

  system func preupgrade() {
    entries := cache.entries();
  };

  system func postupgrade() {
    cache.pruneAll();
  };
}
```

From there, you can simply set values using `cache.put` and get values using `cache.get`. Here is an example of how this works:

```rust
public query func get(key : Text) : async ?Blob {
  let result = cache.get(key);
  switch result {
    case null { null };
    case (?blob) { ?blob };
  };
};

public func put(key : Text, value : Blob) : async () {
  let expiration = 2 * 24 * 60 * 60 * 1000 * 1000 * 1000; // 2 days in nanoseconds
  cache.put(key, value, ?expiration);
};
```

## Http_Request

A primary purpose of this library is to make it easier to work with certified http requests. A common use case is to cache the results of an API call or server-side rendered page.

In your code, you can use the cache to to return cached values, or to upgrade the request to an update, cache the result, and return the result.

Here is an example of how this works:

```rust
import Http "mo:certified-cache/Http";
... 
 var cache = CertifiedCache.fromEntries<Text, Blob>(...);
 
 public query func http_request(req : Http.HttpRequest) : async Http.HttpResponse {
    let cached = cache.get(req.url);
    switch cached {
      case (?body) {
        {
          status_code : Nat16 = 200;
          headers = [("content-type", "text/html"), cache.certificationHeader(req.url)];
          body = body;
          streaming_strategy = null;
          upgrade = null;
        }
      }
      case null {
        return {
          status_code = 404;
          headers = [];
          body = Blob.fromArray([]);
          streaming_strategy = null;
          upgrade = ?true;
        };
      }
    }
 }

 public func http_request_update(req : Http.HttpRequest) : async Http.HttpResponse {
    // Application logic to process the request
    let body = process_request(req);

    // expiry can be null to use the default expiry
    cache.put(req.url, body, null);
    return {
        status_code : Nat16 = 200;
        headers = [("content-type", "text/html")];
        body = page;
        streaming_strategy = null;
        upgrade = null;
    };
 }
```

## Interface

### Static Exports

#### `fromEntries`

```rust
public func fromEntries<K, V>(
  entries : [(K, (V, Nat))],
  keyEq : (K, K) -> Bool,
  keyHash : K -> Hash.Hash,
  keyToBlob : K -> Blob,
  valToBlob : V -> Blob,
  timeToLive : Nat,
) : CertifiedCache<K, V>
```

This is a constructor that will create a new cache from an array of entries. The entries are expected to be in the format `(K, (V, Nat))`, where `K` is the key, `V` is the value, and `Nat` is the expiration time in nanoseconds.

#### `CertifiedCache`

```rust
public class CertifiedCache<K, V> {
  public func entries() : [(K, (V, Nat))];
  public func get(key : K) : ?V;
  public func put(key : K, value : V, ?expiration : ?Nat) : ();
  public func pruneAll() : ();
  public func certificationHeader(key : K) : (Text, Text);
}
```

This is the class that represents the cache. It has the following methods:

- `size() : Nat` - returns the number of entries in the cache

- `get(key : K) : ?V` - returns the value for the given key, if it exists

- `put(key : K, value : V, ?expiration : ?Nat) : ()` - puts the given key-value pair into the cache. If the expiration is not provided, it will use the default expiration time.

- `remove(key : K) : ?V` - removes the given key from the cache. Returns the value if it was present.

- `delete(key : K) : ()` - deletes the given key from the cache. Does not return the value.

- `replace(key : K, value : V, ?expiration : ?Nat) : ?V` - replaces the given key with the given value. Returns the old value if it was present.

- `keys() : [K]` - returns an array of all the keys in the cache

- `vals() : [V]` - returns an array of all the values in the cache

- `entries() : [(K, (V, Nat))]` - returns an array of all the entries in the cache

- `pruneAll() : ()` - removes all expired entries from the cache

- `getExpiry(key: K) : ?Nat` - returns the expiration time for the given key, if it exists

- `certificationHeader(key : K) : (Text, Text)` - returns the certification header for the given key

## Running the Demo

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
