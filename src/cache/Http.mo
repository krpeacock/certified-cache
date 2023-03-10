import Iter "mo:base/Iter";
import Blob "mo:base/Blob";
import O "mo:base/Order";
import Text "mo:base/Text";

module {
  public type StreamingCallbackHttpResponse = {
    body : Blob;
    token : ?Token;
  };

  public type Token = {
    // Add whatever fields you'd like
    arbitrary_data : Text;
  };

  public type CallbackStrategy = {
    callback : shared query (Token) -> async StreamingCallbackHttpResponse;
    token : Token;
  };

  public type StreamingStrategy = {
    #Callback : CallbackStrategy;
  };

  public type HeaderField = (Text, Text);

  public type HttpResponse = {
    status_code : Nat16;
    headers : [HeaderField];
    body : Blob;
    streaming_strategy : ?StreamingStrategy;
    upgrade : ?Bool;
  };

  public type HttpRequest = {
    method : Text;
    url : Text;
    headers : [HeaderField];
    body : Blob;
  };

  public func compare_http_request(a : HttpRequest, b : HttpRequest) : O.Order {
    if (a.url != b.url) {
      return Text.compare(a.url, b.url);
    };
    if (a.method != b.method) {
      return Text.compare(a.method, b.method);
    };
    var count = 0;
    for (header in Iter.fromArray(a.headers)) {
      if (header != b.headers[count]) {
        return Text.compare(header.0, b.headers[count].0);
      };
      count += 1;
    };
    if (not Blob.equal(a.body, b.body)) {
      return Blob.compare(a.body, b.body);
    };

    #equal;
  };

};
