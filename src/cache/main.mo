import RBT "mo:StableRBTree/StableRBTree";
import SHA256 "mo:motoko-sha/SHA256";
import CertTree "mo:ic-certification/CertTree";
import CanisterSigs "mo:ic-certification/CanisterSigs";
import HTTP "./Http";
import Iter "mo:base/Iter";
import Blob "mo:base/Blob";
import Option "mo:base/Option";
import Time "mo:base/Time";
import Text "mo:base/Text";
import Debug "mo:base/Debug";
import Prelude "mo:base/Prelude";
import Principal "mo:base/Principal";

actor Self {
  type HttpRequest = HTTP.HttpRequest;
  type HttpResponse = HTTP.HttpResponse;

  stable var cache = RBT.init<HttpRequest, HttpResponse>();
  stable let cert_store : CertTree.Store = CertTree.newStore();
  let ct = CertTree.Ops(cert_store);
  let csm = CanisterSigs.Manager(ct, null);

  public query func greet(name : Text) : async Text {
    return "Hello, " # name # "!";
  };

  public query func http_request(req : HttpRequest) : async HttpResponse {
    let req_without_headers = {
      method = req.method;
      url = req.url;
      headers = [];
      body = req.body;
    };
    let cached = RBT.get(cache, HTTP.compare_http_request, req_without_headers);
    switch cached {
      case (?r) {
        // Print the body of the response
        let message = Text.decodeUtf8(r.body);
        switch message {
          case (null) {};
          case (?m) {
            Debug.print(m);
          };
        };
        return r;
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
    let cached = RBT.get(cache, HTTP.compare_http_request, req_without_headers);
    switch cached {
      case (?r) { return r };
      case null {
        Debug.print("Storing request in cache.");
        let time = Time.now();
        let message = "<pre>Request has been stored in cache: \n" # "URL is: " # url # "\n" # "Method is " # req.method # "\n" # "Body is: " # debug_show req.body # "\n" # "Timestamp is: \n" # debug_show Time.now() # "\n" # "</pre>";

        let page = page_template(message);

        await store(req.url, page);

        let response : HttpResponse = {
          status_code : Nat16 = 200;
          headers = [];
          body = page;
          streaming_strategy = null;
          upgrade = null;
        };

        cache := RBT.put(cache, HTTP.compare_http_request, req, response);

        return response;
      };
    };
  };

  public shared func store(key : Text, value : Blob) : async () {
    // Store key directly
    ct.put(["store", Text.encodeUtf8(key)], value);
    ct.put(["http_assets", Text.encodeUtf8("/get/" # key)], value);
    update_asset_hash(?key); // will be explained below
  };

  public shared func delete(key : Text) : async () {
    ct.delete(["store", Text.encodeUtf8(key)]);
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
          ct.labelsAt(["store"]),
          func(key : Blob) : Text {
            "<li><a href='/get/" # ofUtf8(key) # "'>" # ofUtf8(key) # "</a></li>";
          },
        ),
      ) # "</ul>" # "<p>And to demonstrate that this really is dynamic, you can store and delete keys using " # "<a href='https://a4gq6-oaaaa-aaaab-qaa4q-cai.raw.ic0.app/?id=" # debug_show my_id() # "'>" # "the Candid UI</a>.</p>" # "<p>The source of this canister can be found at " # "<a href='https://github.com/nomeata/ic-certification/tree/main/demo'>https://github.com/nomeata/ic-certification/tree/main/demo</a>.</p>"
    );
  };

  func value_page(key : Text) : Blob {
    switch (ct.lookup(["store", Text.encodeUtf8(key)])) {
      case (null) { page_template("<p>Key " # key # " not found.</p>") };
      case (?v) {
        page_template(
          "<p>Key " # key # " has value:</p>" # "<pre>" # ofUtf8(v) # "</pre>"
        );
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
        ct.put(["http_assets", Text.encodeUtf8("/get/" # k)], h(value_page(k)));
      };
    };
    // After every modification, we should update the hash.
    ct.setCertifiedData();
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
