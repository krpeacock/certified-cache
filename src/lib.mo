import Map "mo:new-base/Map";
import CertifiedAssets "mo:certified-assets";
import CertifiedData "mo:new-base/CertifiedData";
import Sha256 "mo:sha2/Sha256";
import Iter "mo:new-base/Iter";
import Time "mo:new-base/Time";
import Debug "mo:new-base/Debug";
import Blob "mo:new-base/Blob";
import Nat8 "mo:new-base/Nat8";
import Array "mo:new-base/Array";
import Int "mo:new-base/Int";
import Order "mo:base/Order";
import Text "mo:new-base/Text";
import HttpTypes "mo:http-types";

module {
  public class CertifiedCache<K, V>(
    keyCompare : (K, K) -> Order.Order,
    keyToText : K -> Text,
    textToKey : Text -> ?K,  // Added this function to convert text back to key
    valToBlob : V -> Blob,
    timeToLive : Nat,
  ) {
    var map = Map.empty<K, V>();
    var ExpiryMap = Map.empty<K, Nat>();
    
    // Initialize CertifiedAssets instead of CertTree
    let certs = CertifiedAssets.CertifiedAssets(CertifiedAssets.init_stable_store());

    /* Wraps the HashMap class to provide a familiar interface */
    public func size() : Nat = Map.size(map);
    public func get(key : K) : ?V {
      Map.get(map, keyCompare, key);
    };
    public func put(key : K, value : V, expiry : ?Nat) : () {
      // insert expiry time into ExpiryMap
      switch expiry {
        case null { ignore Map.insert(ExpiryMap, keyCompare, key, timeToLive) };
        case (?e) {
          if (e < Time.now()) {
            // warn that the expiry is in the past
            // Debug.print("Warning: expiry time is in the past");
          } else {
            ignore Map.insert(ExpiryMap, keyCompare, key, e);
          };
        };
      };
      
      // Create endpoint and certify it using CertifiedAssets
      let path = "/" # keyToText(key);
      let endpoint = CertifiedAssets.Endpoint(
        path, 
        ?valToBlob(value)
      ).no_request_certification();
      
      certs.certify(endpoint);
      
      ignore Map.insert(map, keyCompare, key, value);
    };
    
    public func remove(key : K) : ?V {
      // remove expiry time from ExpiryMap
      let _ = Map.delete(ExpiryMap, keyCompare, key);

      // Get the value before removing
      let v = Map.get(map, keyCompare, key);
      
      // Remove certification
      let path = "/" # keyToText(key);
      certs.remove_all(path);
      
      // remove from cache
      switch v {
        case null { Debug.print("Value not found for key"); return null };
        case (?v) { 
          Map.remove(map, keyCompare, key);
          ?v;
         };
      };
    };
    
    public func delete(k : K) = ignore remove(k);

    public func replace(k : K, v : V, e : ?Nat) : ?V {
      // replace expiry time in ExpiryMap
      let newExpiry = switch e {
        case null { timeToLive };
        case (?e) { e };
      };
      ignore Map.insert(ExpiryMap, keyCompare, k, newExpiry);

      // Get the old value
      let oldValue = Map.get(map, keyCompare, k);
      
      // Update certification
      let path = "/" # keyToText(k);
      let endpoint = CertifiedAssets.Endpoint(
        path, 
        ?valToBlob(v)
      ).no_request_certification();
      
      certs.certify(endpoint);

      // replace in cache
      switch oldValue {
        case null { Debug.print("Value not found for key"); return null };
        case (?oldValue) {
          Map.remove(map, keyCompare, k);
          ignore Map.insert(map, keyCompare, k, v);
          ?oldValue;
        };
      };
    };
    
    public func keys() : Iter.Iter<K> {
      Map.keys(map);
    };
    
    public func vals() : Iter.Iter<V> {
      Map.values(map);
    };

    /**
     * This will give you the key-value pairs in the cache
     * along with the expiry time for each key.
     */
    public func entries() : [(K, (V, Nat))] {
      var entries : [(K, (V, Nat))] = [];
      for (k in keys()) {
        let expiry = Map.get(ExpiryMap, keyCompare, k);
        switch expiry {
          case null {
            let v = get(k);
            switch v {
              case null { Debug.print("Value not found for key"); return [] };
              case (?v) {
                let defaultExpiry = Time.now() + timeToLive;
                entries := Array.tabulate<(K, (V, Nat))>(Array.size(entries) + 1, func(i) = 
                  if (i == Array.size(entries)) { (k, (v, Int.abs(defaultExpiry))) } 
                  else { entries[i] }
                );
              };
            };
          };
          case (?e) {
            let v = get(k);
            switch v {
              case null { Debug.print("Value not found for key"); return [] };
              case (?v) {
                entries := Array.tabulate<(K, (V, Nat))>(Array.size(entries) + 1, func(i) = 
                  if (i == Array.size(entries)) { (k, (v, e)) } 
                  else { entries[i] }
                );
              };
            };
          };
        };
      };
      entries;
    };

    /* Expiry Logic */
    public func pruneAll() : [K] {
      let now = Time.now();
      var removed : [K] = [];
      for (k in keys()) {
        let expiry = Map.get(ExpiryMap, keyCompare, k);
        switch expiry {
          case null {
            ignore remove(k);
          };
          case (?e) {
            if (e < now) {
              let _ = remove(k);
              removed := Array.tabulate<K>(Array.size(removed) + 1, func(i) = 
                if (i == Array.size(removed)) { k } 
                else { removed[i] }
              );
            };
          };
        };
      };
      
      // Nothing to do for pruning certificates as we're already removing them in remove()
      removed;
    };

    public func getExpiry(key : K) : ?Nat {
      Map.get(ExpiryMap, keyCompare, key);
    };

    /* Certification Logic */
    public func certificationHeader(url : K) : HttpTypes.Header {
      let path = "/" # keyToText(url);
      let certificate_version: ?Nat16 = ?2;
      let request = {
        certificate_version; // Use version 2 for certified assets
        method = "GET";
        url = path;
        headers = [];
        body = "" : Blob; 
      };
      
      let response : HttpTypes.Response = {
        status_code = 200 : Nat16;
        headers = [];
        body = switch (get(url)) {
          case (?value) valToBlob(value);
          case (null) "Not found" : Blob;
        };
        streaming_strategy = null;
        upgrade = null;
      };
      
      let certResult = certs.get_certified_response(request, response, null);
      
      switch (certResult) {
        case (#ok(certified_response)) {
          // Extract the certificate header
          for ((name, value) in Iter.fromArray(certified_response.headers)) {
            if (name == "ic-certificate") {
              return (name, value);
            };
          };
          
          // If we couldn't find the certificate header
          return ("ic-certificate", "");
        };
        case (#err(errorMsg)) {
          return ("ic-certificate", "Error: " # errorMsg);
        };
      };
    };
    
    // Add a function to get a certified HTTP response
    public func get_certified_response(req : HttpTypes.Request) : HttpTypes.Response {
      let url = req.url;
      let k = switch (getKeyFromUrl(url)) {
        case (?key) key;
        case (null) return {
          status_code = 404;
          body = "Not found" : Blob;
          headers = [];
          streaming_strategy = null;
          upgrade = null;
        };
      };
      
      let response : HttpTypes.Response = {
        status_code = 200 : Nat16;
        headers = [];
        body = switch (get(k)) {
          case (?value) valToBlob(value);
          case (null) "Not found" : Blob;
        };
        streaming_strategy = null;
        upgrade = null;
      };
      
      let result = certs.get_certified_response(req, response, null);
      
      switch (result) {
        case (#ok(certified_response)) certified_response;
        case (#err(errorMsg)) {
          return {
            status_code = 500 : Nat16;
            body = Text.encodeUtf8("Certified Assets Error: " # errorMsg);
            headers = [];
            streaming_strategy = null;
            upgrade = null;
          };
        };
      };
    };
    
    // A helper function to extract the key from URL
    private func getKeyFromUrl(url : Text) : ?K {
      // Extract key from URL path
      var path = url;
      
      // Remove leading slash if present
      if (Text.startsWith(path, #text "/")) {
        path := Text.trimStart(path, #char '/');
      };
      
      // Convert the path to a key using the provided function
      return textToKey(path);
    };
  };

  public func fromEntries<K, V>(
    entries : [(K, (V, Nat))],
    keyCompare : (K, K) -> Order.Order,
    keyToText : K -> Text,
    textToKey : Text -> ?K,  // Added this parameter
    valToBlob : V -> Blob,
    timeToLive : Nat,
  ) : CertifiedCache<K, V> {
    let newCache = CertifiedCache<K, V>(keyCompare, keyToText, textToKey, valToBlob, timeToLive);
    for (entry in Iter.fromArray(entries)) {
      let (k, val_exp) = entry;
      let (v, e) = val_exp;
      newCache.put(k, v, ?e);
    };
    newCache;
  };
};
