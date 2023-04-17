import HashMap "mo:StableHashMap/ClassStableHashMap";
import CertTree "mo:ic-certification/CertTree";
import CanisterSigs "mo:ic-certification/CanisterSigs";
import CertifiedData "mo:base/CertifiedData";
import SHA256 "mo:motoko-sha/SHA256";
import Hash "mo:base/Hash";
import Iter "mo:base/Iter";
import Time "mo:base/Time";
import Option "mo:base/Option";
import Debug "mo:base/Debug";
import HTTP "Http";
import Blob "mo:base/Blob";
import Buffer "mo:base/Buffer";
import Nat8 "mo:base/Nat8";
import Array "mo:base/Array";

module {
  public class CertifiedCache<K, V>(
    initCapacity : Nat,
    keyEq : (K, K) -> Bool,
    keyHash : K -> Hash.Hash,
    keyToBlob : K -> Blob,
    valToBlob : V -> Blob,
    timeToLive : Nat,
  ) {
    var map : HashMap.StableHashMap<K, V> = HashMap.StableHashMap<K, V>(initCapacity, keyEq, keyHash);
    var ExpiryMap : HashMap.StableHashMap<K, Nat> = HashMap.StableHashMap<K, Nat>(initCapacity, keyEq, keyHash);
    var cert_store : CertTree.Store = CertTree.newStore();
    var ct = CertTree.Ops(cert_store);
    var csm = CanisterSigs.Manager(ct, null);

    /* Wraps the HashMap class to provide a familiar interface */
    public func size() : Nat = map.size();
    public func get(key : K) : ?V {
      map.get(key);
    };
    public func put(key : K, value : V, expiry : ?Nat) : () {
      // insert expiry time into ExpiryMap
      switch expiry {
        case null { ExpiryMap.put(key, timeToLive) };
        case (?e) {
          if (e < Time.now()) {
            Debug.trap("Expiry time is in the past");
          } else {
            ExpiryMap.put(key, e);
          };
        };
      };
      // insert into CertTree
      ct.put(["http_assets", keyToBlob(key)], Blob.fromArray(SHA256.sha256(Blob.toArray(valToBlob(value)))));
      ct.setCertifiedData();

      map.put(key, value);
    };
    public func remove(key : K) : ?V {
      // remove expiry time from ExpiryMap
      let _ = ExpiryMap.remove(key);

      // remove from CertTree
      ct.delete(["http_assets", keyToBlob(key)]);
      ct.setCertifiedData();

      // remove from cache
      map.remove(key);
    };
    public func delete(k : K) = ignore remove(k);

    public func replace(k : K, v : V, e : ?Nat) : ?V {
      // replace expiry time in ExpiryMap
      let newExpiry = switch e {
        case null { timeToLive };
        case (?e) { e };
      };
      let _ = ExpiryMap.replace(k, newExpiry);

      // replace in CertTree
      ct.put(["http_assets", keyToBlob(k)], valToBlob(v));
      ct.setCertifiedData();

      // replace in cache
      map.replace(k, v);
    };
    public func keys() : Iter.Iter<K> {
      map.keys();
    };
    public func vals() : Iter.Iter<V> {
      map.vals();
    };

    /** 
     * This will give you the key-value pairs in the cache
     * along with the expiry time for each key.
     */
    public func entries() : [(K, (V, Nat))] {
      var mapped = Buffer.fromArray<(K, (V, Nat))>([]);
      for (k in keys()) {
        let expiry = ExpiryMap.get(k);
        switch expiry {
          case null { Debug.trap("Expiry time not found for key") };
          case (?e) {
            let v = get(k);
            switch v {
              case null { Debug.trap("Value not found for key") };
              case (?v) {
                mapped.add((k, (v, e)));
              };
            };
          };
        };
      };

      Buffer.toArray(mapped);
    };

    /* Expiry Logic */
    public func pruneAll() : [K] {
      let now = Time.now();
      let removed = Buffer.fromArray<K>([]);
      for (k in keys()) {
        let expiry = ExpiryMap.get(k);
        switch expiry {
          case null { Debug.trap("Expiry time not found for key") };
          case (?e) {
            if (e < now) {
              let _ = remove(k);
              removed.add(k);
            };
          };
        };
      };
      csm.pruneAll();
      Buffer.toArray(removed);
    };

    public func getExpiry(key : K) : ?Nat {
      ExpiryMap.get(key);
    };

    /* Certification Logic */

    private func base64(b : Blob) : Text {
      let base64_chars : [Text] = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "+", "/"];
      let bytes = Blob.toArray(b);
      let pad_len = if (bytes.size() % 3 == 0) { 0 } else {
        3 - bytes.size() % 3 : Nat;
      };
      let buf = Buffer.fromArray<Nat8>(bytes);
      for (_ in Iter.range(0, pad_len -1)) { buf.add(0) };
      let padded_bytes = Buffer.toArray(buf);
      var out = "";
      for (j in Iter.range(1, padded_bytes.size() / 3)) {
        let i = j - 1 : Nat; // annoying inclusive upper bound in Iter.range
        let b1 = padded_bytes[3 * i];
        let b2 = padded_bytes[3 * i +1];
        let b3 = padded_bytes[3 * i +2];
        let c1 = (b1 >> 2) & 63;
        let c2 = (b1 << 4 | b2 >> 4) & 63;
        let c3 = (b2 << 2 | b3 >> 6) & 63;
        let c4 = (b3) & 63;
        out #= base64_chars[Nat8.toNat(c1)] # base64_chars[Nat8.toNat(c2)] # (if (3 * i +1 >= bytes.size()) { "=" } else { base64_chars[Nat8.toNat(c3)] }) # (if (3 * i +2 >= bytes.size()) { "=" } else { base64_chars[Nat8.toNat(c4)] });
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
          // here, because this function isn’t async, but we can’t make it async
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
    keyEq : (K, K) -> Bool,
    keyHash : K -> Hash.Hash,
    keyToBlob : K -> Blob,
    valToBlob : V -> Blob,
    timeToLive : Nat,
  ) : CertifiedCache<K, V> {
    let initCapacity = Array.size(entries);
    let newCache = CertifiedCache<K, V>(initCapacity, keyEq, keyHash, keyToBlob, valToBlob, timeToLive);
    for (entry in Iter.fromArray(entries)) {
      let (k, val_exp) = entry;
      let (v, e) = val_exp;
      newCache.put(k, v, ?e);
    };
    newCache;
  };

};
