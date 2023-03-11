import RBT "mo:StableRBTree/StableRBTree";
import MerkleTree "mo:motoko-merkle-tree/MerkleTree";
import Iter "mo:base/Iter";
import Blob "mo:base/Blob";
import Option "mo:base/Option";
import Time "mo:base/Time";
import Text "mo:base/Text";
import Debug "mo:base/Debug";
import CertifiedData "mo:base/CertifiedData";
import HTTP "./Http";
import Certified "./Certified";
import Buffer "mo:base/Buffer";

actor {
  type HttpRequest = HTTP.HttpRequest;
  type HttpResponse = HTTP.HttpResponse;
  type HashTree = Certified.HashTree;

  type URL = Blob;
  type Body = Blob;

  stable var cache = RBT.init<URL, Body>();
  var http_assets_tree = MerkleTree.empty();

  public query func greet(name : Text) : async Text {
    return "Hello, " # name # "!";
  };

  public query func http_request(req : HttpRequest) : async HttpResponse {
    let url = Text.encodeUtf8(req.url);
    let cached = RBT.get(cache, Blob.compare, url);
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

        Debug.print("certificate: " # debug_show certificate_header(url));
        return {
          status_code = 200;
          headers = [
            ("content-type", "text/plain"),
            certificate_header(url),
          ];
          body = body;
          streaming_strategy = null;
          upgrade = null;
        };
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
    let url = Text.encodeUtf8(req.url);
    let cached = RBT.get(cache, Blob.compare, url);
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
        return {
          status_code = 200;
          headers = [
            ("content-type", "text/plain"),
            certificate_header(url),
          ];
          body = body;
          streaming_strategy = null;
          upgrade = null;
        };
      };
      case null {
        Debug.print("Storing request in cache.");
        let time = Time.now();
        let message = "URL is " # req.url # " and time cached is " # debug_show time;

        let body = Text.encodeUtf8(message);
        cache := RBT.put(cache, Blob.compare, url, body);
        http_assets_tree := MerkleTree.put(http_assets_tree, url, Certified.h(body));

        let hashTree = MerkleTree.witnessUnderLabel(Text.encodeUtf8("http_assets"), compute_witness());
        CertifiedData.set(Certified.hash_tree(hashTree));

        let response : HttpResponse = {
          status_code : Nat16 = 200;
          headers = [("content-type", "text/plain"), certificate_header(url)];
          body = body;
          streaming_strategy = null;
          upgrade = null;
        };

        return response;
      };
    };
  };

  func compute_witness() : HashTree {
    let keys : Buffer.Buffer<Blob> = Buffer.fromArray([]);
    for ((URL, Body) in RBT.entries(cache)) {
      keys.add(URL);
    };
    MerkleTree.reveals(http_assets_tree, Iter.fromArray(Buffer.toArray(keys)));
  };

  func certificate_header(url : Blob) : (Text, Text) {
    let hashTree = MerkleTree.witnessUnderLabel(Text.encodeUtf8("http_assets"), compute_witness());
    let certificate = Certified.certification_header(
      func() : Certified.HashTree {
        hashTree;
      },
    );
    return certificate;
  };

};
