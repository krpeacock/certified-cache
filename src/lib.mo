import Map "mo:new-base/Map";
import CertTree "mo:ic-certification/CertTree";
import CanisterSigs "mo:ic-certification/CanisterSigs";
import CertifiedData "mo:new-base/CertifiedData";
import Sha256 "mo:sha2/Sha256";
import Iter "mo:new-base/Iter";
import Time "mo:new-base/Time";
import Debug "mo:new-base/Debug";
import HTTP "Http";
import Blob "mo:new-base/Blob";
import Nat8 "mo:new-base/Nat8";
import Array "mo:new-base/Array";
import Int "mo:new-base/Int";
import Order "mo:base/Order";
import Bool "mo:base/Bool";

module {
  public class CertifiedCache<K, V>(
    initCapacity : Nat,
    keyEq : (K, K) -> Order.Order,
    keyToBlob : K -> Blob,
    valToBlob : V -> Blob,
    timeToLive : Nat,
  ) {
    var map = Map.empty<K, V>();
    var ExpiryMap = Map.empty<K, Nat>();
    var cert_store : CertTree.Store = CertTree.newStore();
    var ct = CertTree.Ops(cert_store);
    var csm = CanisterSigs.Manager(ct, null);

    /* Wraps the HashMap class to provide a familiar interface */
    public func size() : Nat = Map.size(map);
    public func get(key : K) : ?V {
      Map.get(map, keyEq, key);
    };
    public func put(key : K, value : V, expiry : ?Nat) : () {
      // insert expiry time into ExpiryMap
      switch expiry {
        case null { ignore Map.insert(ExpiryMap, keyEq, key, timeToLive) };
        case (?e) {
          if (e < Time.now()) {
            // warn that the expiry is in the past
            // Debug.print("Warning: expiry time is in the past");
          } else {
            ignore Map.insert(ExpiryMap, keyEq, key, e);
          };
        };
      };
      // insert into CertTree
      ct.put(["http_assets", keyToBlob(key)], Sha256.fromBlob(#sha256, valToBlob(value)));
      ct.setCertifiedData();

      ignore Map.insert(map, keyEq, key, value);
    };
    public func remove(key : K) : ?V {
      // remove expiry time from ExpiryMap
      let _ = Map.delete(ExpiryMap, keyEq, key);

      // remove from CertTree
      ct.delete(["http_assets", keyToBlob(key)]);
      ct.setCertifiedData();

      // remove from cache
      let v = Map.get(map, keyEq, key);
      switch v {
        case null { Debug.print("Value not found for key"); return null };
        case (?v) { 
          Map.remove(map, keyEq, key);
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
      ignore Map.insert(ExpiryMap, keyEq, k, newExpiry);

      // replace in CertTree
      ct.put(["http_assets", keyToBlob(k)], valToBlob(v));
      ct.setCertifiedData();

      // replace in cache
      let oldValue = Map.get(map, keyEq, k);
      switch oldValue {
        case null { Debug.print("Value not found for key"); return null };
        case (?oldValue) {
          Map.remove(map, keyEq, k);
          ignore Map.insert(map, keyEq, k, v);
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
        let expiry = Map.get(ExpiryMap, keyEq, k);
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
        let expiry = Map.get(ExpiryMap, keyEq, k);
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
      csm.pruneAll();
      removed;
    };

    public func getExpiry(key : K) : ?Nat {
      Map.get(ExpiryMap, keyEq, key);
    };

    /* Certification Logic */

    private func base64(b : Blob) : Text {
      let base64_chars : [Text] = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "+", "/"];
      let bytes = Blob.toArray(b);
      let pad_len = if (bytes.size() % 3 == 0) { 0 } else {
        3 - bytes.size() % 3 : Nat;
      };
      var padded_bytes = bytes;
      var i = 0;
      while (i < pad_len) {
        padded_bytes := Array.tabulate<Nat8>(Array.size(padded_bytes) + 1, func(j) = 
          if (j == Array.size(padded_bytes)) { 0 } 
          else { padded_bytes[j] }
        );
        i += 1;
      };
      var out = "";
      i := 0;
      while (i < padded_bytes.size() / 3) {
        let b1 = padded_bytes[3 * i];
        let b2 = padded_bytes[3 * i + 1];
        let b3 = padded_bytes[3 * i + 2];
        let c1 = (b1 >> 2) & 63;
        let c2 = (b1 << 4 | b2 >> 4) & 63;
        let c3 = (b2 << 2 | b3 >> 6) & 63;
        let c4 = (b3) & 63;
        out #= base64_chars[Nat8.toNat(c1)] # base64_chars[Nat8.toNat(c2)] # (if (3 * i + 1 >= bytes.size()) { "=" } else { base64_chars[Nat8.toNat(c3)] }) # (if (3 * i + 2 >= bytes.size()) { "=" } else { base64_chars[Nat8.toNat(c4)] });
        i += 1;
      };
      return out;
    };
    public func certificationHeader(url : K) : HTTP.HeaderField {
      let witness = ct.reveal(["http_assets", keyToBlob(url)]);
      let encoded = ct.encodeWitness(witness);
      let cert = switch (CertifiedData.getCertificate()) {
        case (?c) c;
        case null {
          // unfortunately, we cannot do
          //   throw Error.reject("getCertificate failed. Call this as a query call!")
          // here, because this function isn't async, but we can't make it async
          // because it is called from a query (and it would do the wrong thing) :-(
          //
          // So just return erronous data instead
          "getCertificate failed. Call this as a query call!" : Blob;
        };
      };
      return (
        "ic-certificate",
        "certificate=:" # base64(cert) # ":, " # "tree=:" # base64(encoded) # ":",
      );
    };
  };

  public func fromEntries<K, V>(
    entries : [(K, (V, Nat))],
    keyEq : (K, K) -> Order.Order,
    keyToBlob : K -> Blob,
    valToBlob : V -> Blob,
    timeToLive : Nat,
  ) : CertifiedCache<K, V> {
    let initCapacity = Array.size(entries);
    let newCache = CertifiedCache<K, V>(initCapacity, keyEq, keyToBlob, valToBlob, timeToLive);
    for (entry in Iter.fromArray(entries)) {
      let (k, val_exp) = entry;
      let (v, e) = val_exp;
      newCache.put(k, v, ?e);
    };
    newCache;
  };
};
