/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 3 21, 2015
 * License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.http;

import vibedav.base;

import std.datetime;
import std.string;

import vibe.http.server;
import vibe.inet.message;
import vibe.core.file;
import vibe.stream.operations;
import vibe.utils.dictionarylist;

import tested;


alias HeaderList = DictionaryList!(string, false, 32L);

string getHeaderValue(HeaderList headers, string name, string defaultValue = "") {

	string value = defaultValue;

	if(name !in headers && defaultValue == "")
		throw new DavException(HTTPStatus.internalServerError, "Can't find '"~name~"' in headers.");
	else
		value = headers.get(name, defaultValue);

	return value;
}

@name("basic check for getHeaderValue")
unittest {
	HeaderList list;
	list["key"] = "value";
	auto val = getHeaderValue(list, "key");
	assert(val == "value");
}

@name("getHeaderValue with default value")
unittest {
	HeaderList list;
	auto val = getHeaderValue(list, "key", "default");
	assert(val == "default");
}

@name("check if getHeaderValue fails")
unittest {
	bool raised = false;

	try {
		HeaderList list;
		list["key"] = "value";
		getHeaderValue(list, "key1");
	} catch(DavException e) {
		raised = true;
	}

	assert(raised);
}

void enforce(string[] valid)(string value) {
	bool isValid;

	foreach(validValue; valid)
		if(value == validValue)
			isValid = true;

	if(!isValid)
		throw new DavException(HTTPStatus.internalServerError, "Invalid value.");
}

string getHeader(string name)(HeaderList headers) {
	string value;

	static if(name == "Depth") {
		value = getHeaderValue(headers, name, "infinity");
		value.enforce!(["0", "1", "infinity"]);
	} else static if(name == "Overwrite") {
		value = getHeaderValue(headers, name, "F");
		value.enforce!(["T", "F"]);
	} else static if(name == "If") {
		value = getHeaderValue(headers, name, "()");
	} else static if(name == "Content-Length") {
		value = getHeaderValue(headers, name, "0");
	} else {
		value = getHeaderValue(headers, name);
	}

	return value;
}

/// The HTTP response wrapper
struct DavResponse {
	private {
		HTTPServerResponse response;
		string _content;
	}

	HTTPStatus statusCode = HTTPStatus.ok;

	@property {
		void content(string value) {
			_content = value;
		}

		void mimeType(string value) {
			response.headers["Content-Type"] = value;
		}
	}

	this(HTTPServerResponse res) {
		this.response = res;
		this.response.headers["Content-Type"] = "text/plain";
	}

	void opIndexAssign(T)(string value, T key) {
		static if(is( T == string )) {
			response.headers[key] = value;
		} else {
			response.headers[key] = value.to!string;
		}
	}

	string opIndex(string key) {
		return response.headers[key];
	}

	static DavResponse Create() {
		import vibe.stream.stdio;
		import vibe.utils.memory;

		StdFileStream conn = new StdFileStream(false, true);
		ConnectionStream raw_connection = new StdFileStream(false, true);
		HTTPServerSettings settings = new HTTPServerSettings;
		Allocator req_alloc = defaultAllocator();

		HTTPServerResponse response = new HTTPServerResponse(conn, raw_connection, settings, req_alloc);
		return DavResponse(response);
	}

	@name("Test opIndex")
	unittest {
		DavResponse davResponse = DavResponse.Create;
		davResponse["test"] = "value";
		assert(davResponse["test"] == "value");
	}

	void flush() {
		response.statusCode = statusCode;
		writeln("\n", _content);
		response.writeBody(_content, response.headers["Content-Type"]);
	}

	void flush(DavResource resource) {
		response.statusCode = statusCode;
		response.writeRawBody(resource.stream);
	}
}

/// The HTTP request wrapper
struct DavRequest {
	private HTTPServerRequest request;

	this(HTTPServerRequest req) {
		request = req;
	}

	@property {
		string path() {
			return request.path;
		}

		string lockToken() {
			return getHeader!"Lock-Token"(request.headers)[1..$-1];
		}

		DavDepth depth() {
			if("depth" in request.headers) {
				string strDepth = getHeader!"Depth"(request.headers);

				if(strDepth == "0") return DavDepth.zero;
				if(strDepth == "1") return DavDepth.one;
			}

			return DavDepth.infinity;
		}

		ulong contentLength() {

			string value = "0";

			if("Content-Length" in request.headers)
				value = getHeader!"Content-Length"(request.headers);
			else if("Transfer-Encoding" in request.headers && "X-Expected-Entity-Length" in request.headers) {
				enforceBadRequest(request.headers["Transfer-Encoding"] == "chunked" ||
								  request.headers["Transfer-Encoding"] == "Chunked");
				value = getHeader!"X-Expected-Entity-Length"(request.headers);
			}

			return value.to!ulong;
		}

		DavProp content() {
			DavProp document;
			string requestXml = cast(string)request.bodyReader.readAllUTF8;

			writeln("requestXml:", requestXml);

			if(requestXml.length > 0) {
				try document = requestXml.parseXMLProp;
				catch (DavPropException e)
					throw new DavException(HTTPStatus.badRequest, "Invalid xml body.");
			}

			return document;
		}

		ubyte[] rawContent() {
			return request.bodyReader.readAll;
		}

		InputStream stream() {
			return request.bodyReader;
		}

		URL url() {
			return request.fullURL;
		}

		string requestUrl() {
			return request.requestURL;
		}

		Duration timeout() {
			Duration t;

			string strTimeout = getHeader!"Timeout"(request.headers);
			auto secIndex = strTimeout.indexOf("Second-");

			if(strTimeout.indexOf("Infinite") != -1) {
				t = dur!"hours"(24);
			} else if(secIndex != -1) {
				auto val = strTimeout[secIndex+7..$].to!int;
				t = dur!"seconds"(val);
			} else {
				throw new DavException(HTTPStatus.internalServerError, "Invalid timeout value");
			}

			return t;
		}

		IfHeader ifCondition() {
			return IfHeader.parse(getHeader!"If"(request.headers));
		}


		URL destination() {
			return URL(getHeader!"Destination"(request.headers));
		}

		bool overwrite() {
			return getHeader!"Overwrite"(request.headers) == "T";
		}

		static DavRequest Create() {
			HTTPServerRequest req = new HTTPServerRequest(Clock.currTime, 0);

			return DavRequest(req);
		}

		string username() {
			return request.username;
		}
	}

	bool ifModifiedSince(DavResource resource) {
		if( auto pv = "If-Modified-Since" in request.headers )
			if( *pv == toRFC822DateTimeString(resource.lastModified) )
				return false;

		return true;
	}

	bool ifNoneMatch(DavResource resource) {
		if( auto pv = "If-None-Match" in request.headers )
			if ( *pv == resource.eTag )
				return false;

		return true;
	}
}

/// A structure that helps to create the propfind response
struct PropfindResponse {

	DavResource list[];

	string toString() {
		bool[string] props;
		return toStringProps(props);
	}

	string toStringProps(bool[string] props) {
		string str = `<?xml version="1.0" encoding="UTF-8"?>`;
		auto response = parseXMLProp(`<d:multistatus xmlns:d="DAV:"></d:multistatus>`);

		foreach(item; list) {
			item.filterProps(response["d:multistatus"], props);
		}

		return str ~ response.toString;
	}
}


