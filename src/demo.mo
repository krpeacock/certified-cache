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
import CertifiedCache "lib";
import Int "mo:base/Int";

actor Self {
  type HttpRequest = HTTP.HttpRequest;
  type HttpResponse = HTTP.HttpResponse;

  var two_days_in_nanos = 2 * 24 * 60 * 60 * 1000 * 1000 * 1000;

  stable var entries : [(Text, (Blob, Nat))] = [];
  var cache = CertifiedCache.fromEntries<Text, Blob>(
    entries,
    Text.equal,
    Text.hash,
    Text.encodeUtf8,
    func(b : Blob) : Blob { b },
    two_days_in_nanos + Int.abs(Time.now()),
  );

  public query func keys() : async [Text] {
    return Iter.toArray(cache.keys());
  };

  public query func http_request(req : HttpRequest) : async HttpResponse {
    let req_without_headers = {
      method = req.method;
      url = req.url;
      headers = [];
      body = req.body;
    };

    let cached = cache.get(req.url);

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
          headers = [("content-type", "text/html"), cache.certificationHeader(req.url)];
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

    Debug.print("Storing request in cache.");
    let time = Time.now();
    let message = "<pre>Request has been stored in cache: \n" # "URL is: " # url # "\n" # "Method is " # req.method # "\n" # "Body is: " # debug_show req.body # "\n" # "Timestamp is: \n" # debug_show Time.now() # "\n" # "</pre>";

    if (req.url == "/" or req.url == "/index.html") {
      let page = main_page();
      let response : HttpResponse = {
        status_code : Nat16 = 200;
        headers = [("content-type", "text/html")];
        body = page;
        streaming_strategy = null;
        upgrade = null;
      };

      let put = cache.put(req.url, page, null);
      return response;
    } else {
      let page = page_template(message);

      let response : HttpResponse = {
        status_code : Nat16 = 200;
        headers = [("content-type", "text/html")];
        body = page;
        streaming_strategy = null;
        upgrade = null;
      };

      let put = cache.put(req.url, page, null);

      // update index
      let indexBody = main_page();
      cache.put("/", indexBody, null);

      return response;
    };
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
      "<p>This canister demonstrates certified HTTP assets from Motoko.</p>" # "<p>You can see this text at <tt>https://" # debug_show my_id() # ".ic0.app/</tt> " # "(note, no <tt>raw</tt> in the URL!) and it will validate!</p>" # "<p>This canister is dynamic, and uses http_request updates to store any visited route as a cached \"asset\". Here is the list of " # "cached routes:</p>" # "<ul>" #
      Text.join(
        "",
        Iter.map(
          cache.keys(),
          func(key : Text) : Text {
            "<li><a href='" # key # "'>" # key # "</a></li>";
          },
        ),
      ) # "</ul>" # "<p>And to demonstrate that this really is dynamic, you can visit a new route and it will show up in this list.<pp>" # "<p>Code for this canister can be found at " # "<a href='https://github.com/krpeacock/cache-example'>https://github.com/krpeacock/cache-example</a>.</p>"

      # "<p>Many thanks to Joachim for the certification library behind this package, at <a href='https://github.com/nomeata/ic-certification/tree/main/demo'>https://github.com/nomeata/ic-certification/tree/main/demo</a>.</p>",
    );
  };

  func value_page(key : Text) : Blob {
    switch (cache.get(key)) {
      case (null) { page_template("<p>Key " # key # " not found.</p>") };
      case (?v) {
        v;
      };
    };
  };

  /*
  * Convenience function to implement SHA256 on Blobs rather than [Int8]
  */
  func h(b1 : Blob) : Blob {
    let d = SHA256.Digest();
    d.write(Blob.toArray(b1));
    Blob.fromArray(d.sum());
  };

  system func preupgrade() {
    entries := cache.entries();
  };

  // If your CertTree.Store is stable, it is recommended to prune all signatures in pre or post-upgrade:
  system func postupgrade() {
    let _ = cache.pruneAll();
  };

};
