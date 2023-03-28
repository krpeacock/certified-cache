import FHM "mo:StableHashMap/FunctionalStableHashMap";
import SHA256 "mo:motoko-sha/SHA256";
import CertTree "mo:ic-certification/CertTree";
import CanisterSigs "mo:ic-certification/CanisterSigs";
import CertifiedData "mo:base/CertifiedData";
import HTTP "./Http";
import Iter "mo:base/Iter";
import Blob "mo:base/Blob";
import Option "mo:base/Option";
import Time "mo:base/Time";
import Text "mo:base/Text";
import Debug "mo:base/Debug";
import Prelude "mo:base/Prelude";
import Principal "mo:base/Principal";
import Buffer "mo:base/Buffer";
import Nat8 "mo:base/Nat8";

actor Self {
  type HttpRequest = HTTP.HttpRequest;
  type HttpResponse = HTTP.HttpResponse;

  stable var cache = FHM.init<Text, Blob>();
  stable let cert_store : CertTree.Store = CertTree.newStore();
  let ct = CertTree.Ops(cert_store);
  let csm = CanisterSigs.Manager(ct, null);

  public query func http_request(req : HttpRequest) : async HttpResponse {
    let req_without_headers = {
      method = req.method;
      url = req.url;
      headers = [];
      body = req.body;
    };

    if (req.url == "/" or req.url == "/index.html") {
      let hasCertifiedData = Option.isSome(ct.lookup(["http_assets", Text.encodeUtf8("/")]));
      if (hasCertifiedData) {
        let page = main_page();
        let response : HttpResponse = {
          status_code : Nat16 = 200;
          headers = [("content-type", "text/html"), certification_header(req.url)];
          body = page;
          streaming_strategy = null;
          upgrade = null;
        };
        return response;
      } else {
        return {
          status_code = 404;
          headers = [];
          body = Blob.fromArray([]);
          streaming_strategy = null;
          upgrade = ?true;
        };
      };
    };

    let cached = FHM.get<Text, Blob>(cache, Text.equal, Text.hash, req.url);
    switch cached {
      case (?body) {
        // Print the body of the response
        let message = Text.decodeUtf8(body);
        switch message {
          case (null) {};
          case (?m) {
            Debug.print(m);
          };
        };
        let response : HttpResponse = {
          status_code : Nat16 = 200;
          headers = [("content-type", "text/html"), certification_header(req.url)];
          body = body;
          streaming_strategy = null;
          upgrade = null;
        };

        return response;
      };
      case null {
        Debug.print("Request was not found in cache. Upgrading to update request.\n");
        return {
          status_code = 404;
          headers = [];
          body = Blob.fromArray([]);
          streaming_strategy = null;
          upgrade = ?true;
        };
      };
    };
  };

  public func http_request_update(req : HttpRequest) : async HttpResponse {
    let req_without_headers = {
      method = req.method;
      url = req.url;
      headers = [];
      body = req.body;
    };
    let url = req.url;
    let cached = FHM.get<Text, Blob>(cache, Text.equal, Text.hash, req.url);
    switch cached {
      case (?body) {
        let response : HttpResponse = {
          status_code : Nat16 = 200;
          headers = [("content-type", "text/html"), certification_header(req.url)];
          body = body;
          streaming_strategy = null;
          upgrade = null;
        };
      };
      case null {
        Debug.print("Storing request in cache.");
        let time = Time.now();
        let message = "<pre>Request has been stored in cache: \n" # "URL is: " # url # "\n" # "Method is " # req.method # "\n" # "Body is: " # debug_show req.body # "\n" # "Timestamp is: \n" # debug_show Time.now() # "\n" # "</pre>";

        if (req.url == "/" or req.url == "/index.html") {
          let page = main_page();
          update_asset_hash(?req.url);
          let response : HttpResponse = {
            status_code : Nat16 = 200;
            headers = [("content-type", "text/html"), certification_header(req.url)];
            body = page;
            streaming_strategy = null;
            upgrade = null;
          };
          FHM.put(cache, Text.equal, Text.hash, req.url, page);
          return response;
        } else {
          let page = page_template(message);

          await store(req.url, page);

          let response : HttpResponse = {
            status_code : Nat16 = 200;
            headers = [("content-type", "text/html"), certification_header(req.url)];
            body = page;
            streaming_strategy = null;
            upgrade = null;
          };

          FHM.put(cache, Text.equal, Text.hash, req.url, page);
          return response;
        };
      };
    };
  };

  public shared func store(key : Text, value : Blob) : async () {
    // Store key directly
    ct.put(["http_assets", Text.encodeUtf8(key)], value);
    update_asset_hash(?key); // will be explained below
  };

  public shared func delete(key : Text) : async () {
    ct.delete(["http_assets", Text.encodeUtf8(key)]);
    update_asset_hash(?key); // will be explained below
  };

  // We put the blobs in the tree, we know they are valid
  func ofUtf8(b : Blob) : Text {
    switch (Text.decodeUtf8(b)) {
      case (?t) t;
      case null { Debug.trap("Internal error: invalid utf8") };
    };
  };

  func page_template(body : Text) : Blob {
    return Text.encodeUtf8(
      "<html>" # "<head>" # "<meta name='viewport' content='width=device-width, initial-scale=1'>" # "<link rel='stylesheet' href='https://unpkg.com/chota@latest'>" # "<title>IC certified assets demo</title>" # "</head>" # "<body>" # "<div class='container' role='document'>" #
      body # "</div>" # "</body>" # "</html>"
    );
  };

  func my_id() : Principal = Principal.fromActor(Self);

  func main_page() : Blob {
    page_template(
      "<p>This canister demonstrates certified HTTP assets from Motoko.</p>" # "<p>You can see this text at <tt>https://" # debug_show my_id() # ".ic0.app/</tt> " # "(note, no <tt>raw</tt> in the URL!) and it will validate!</p>" # "<p>This canister is dynamic, and implements a simple key-value store. Here is the list of " # "keys:</p>" # "<ul>" #
      Text.join(
        "",
        Iter.map(
          ct.labelsAt(["http_assets"]),
          func(key : Blob) : Text {
            "<li><a href='" # ofUtf8(key) # "'>" # ofUtf8(key) # "</a></li>";
          },
        ),
      ) # "</ul>" # "<p>And to demonstrate that this really is dynamic, you can store and delete keys using " # "<a href='https://a4gq6-oaaaa-aaaab-qaa4q-cai.raw.ic0.app/?id=" # debug_show my_id() # "'>" # "the Candid UI</a>.</p>" # "<p>The source of this canister can be found at " # "<a href='https://github.com/nomeata/ic-certification/tree/main/demo'>https://github.com/nomeata/ic-certification/tree/main/demo</a>.</p>"
    );
  };

  func value_page(key : Text) : Blob {
    switch (ct.lookup(["http_assets", Text.encodeUtf8(key)])) {
      case (null) { page_template("<p>Key " # key # " not found.</p>") };
      case (?v) {
        v;
      };
    };
  };

  func update_asset_hash(ok : ?Text) {
    // Always update main page
    ct.put(["http_assets", "/"], h(main_page()));
    // Update the page at that key
    switch (ok) {
      case null {};
      case (?k) {
        ct.put(["http_assets", Text.encodeUtf8(k)], h(value_page(k)));
      };
    };
    // After every modification, we should update the hash.
    ct.setCertifiedData();
  };
  func base64(b : Blob) : Text {
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

  /*
The other use of the tree is when calculating the ic-certificate header. This header
contains the certificate obtained from the system, which we just pass through,
and a witness calculated from hash tree that reveals the hash of the current
value of the main page.
*/

  func certification_header(url : Text) : HTTP.HeaderField {
    let witness = ct.reveal(["http_assets", Text.encodeUtf8(url)]);
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

  /*
  * Convenience function to implement SHA256 on Blobs rather than [Int8]
  */
  func h(b1 : Blob) : Blob {
    let d = SHA256.Digest();
    d.write(Blob.toArray(b1));
    Blob.fromArray(d.sum());
  };

  // If your CertTree.Store is stable, it is recommended to prune all signatures in pre or post-upgrade:
  system func postupgrade() {
    csm.pruneAll();
  };

};
