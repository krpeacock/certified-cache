import RBT "mo:StableRBTree/StableRBTree";
import HTTP "./Http";
import Iter "mo:base/Iter";
import Blob "mo:base/Blob";
import Option "mo:base/Option";
import Time "mo:base/Time";
import Text "mo:base/Text";
import Debug "mo:base/Debug";

actor {
  type HttpRequest = HTTP.HttpRequest;
  type HttpResponse = HTTP.HttpResponse;

  stable var cache = RBT.init<HttpRequest, HttpResponse>();

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
        Debug.print("Request was found in cache. Returning cached response:\n" # debug_show Text.decodeUtf8(r.body) # "\n");
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
        let message = "Request has been stored in cache: \nURL is: " # url # ".\nMethod is " # req.method # "\nBody is: \n" # debug_show req.body # "." # "\nTimestamp is: \n" # debug_show Time.now() # ".";

        let response : HttpResponse = {
          status_code : Nat16 = 200;
          headers = [];
          body = Text.encodeUtf8(message);
          streaming_strategy = null;
          upgrade = null;
        };

        cache := RBT.put(cache, HTTP.compare_http_request, req, response);

        return response;
      };
    };
  };

};
