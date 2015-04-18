/**
 * Authors: Szabo Bogdan <szabobogdan@yahoo.com>
 * Date: 2 15, 2015
 * License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
 * Copyright: Public Domain
 */
module vibedav.base;

public import vibedav.prop;
public import vibedav.ifheader;
public import vibedav.locks;
public import vibedav.http;
public import vibedav.user;
public import vibedav.davresource;

import vibe.core.log;
import vibe.core.file;
import vibe.inet.mimetypes;
import vibe.inet.message;
import vibe.http.server;
import vibe.http.router : URLRouter;
import vibe.stream.operations;
import vibe.internal.meta.uda;

import std.conv : to;
import std.algorithm;
import std.file;
import std.path;
import std.digest.md;
import std.datetime;
import std.string;
import std.stdio;
import std.typecons;
import std.uri;
import tested;

class DavStorage {
	static {
		DavLockList locks;
		DavProp[string] resourcePropStorage;
	}
}

class DavException : Exception {
	HTTPStatus status;
	string mime;

	///
	this(HTTPStatus status, string msg, string mime = "plain/text", string file = __FILE__, size_t line = __LINE__, Throwable next = null)
	{
		super(msg, file, line, next);
		this.status = status;
		this.mime = mime;
	}

	///
	this(HTTPStatus status, string msg, Throwable next, string mime = "plain/text", string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, next, file, line);
		this.status = status;
		this.mime = mime;
	}
}

interface IDavResourceAccess {
	bool exists(URL url);
	bool canCreateCollection(URL url);
	bool canCreateResource(URL url);

	void removeResource(URL url, IDavUser user = null);
	DavResource getResource(URL url, IDavUser user = null);
	DavResource createCollection(URL url);
	DavResource createResource(URL url);
}

interface IDavPlugin : IDavResourceAccess {
	@property {
		IDav dav();
		string name();

		string[] support();
	}
}

interface IDavPluginHub {
	void registerPlugin(IDavPlugin plugin);
	bool hasPlugin(string name);
}

interface IDav : IDavResourceAccess, IDavPluginHub {
	void options(DavRequest request, DavResponse response);
	void propfind(DavRequest request, DavResponse response);
	void lock(DavRequest request, DavResponse response);
	void get(DavRequest request, DavResponse response);
	void put(DavRequest request, DavResponse response);
	void proppatch(DavRequest request, DavResponse response);
	void mkcol(DavRequest request, DavResponse response) ;
	void remove(DavRequest request, DavResponse response);
	void move(DavRequest request, DavResponse response);
	void copy(DavRequest request, DavResponse response);


	@property
	Path rootUrl();
}

/// The main DAV protocol implementation
class Dav : IDav {
	protected {
		Path _rootUrl;

		IDavPlugin[] plugins;
	}

	IDavUserCollection userCollection;

	@property
	Path rootUrl() {
		return _rootUrl;
	}

	this(string rootUrl) {
		_rootUrl = rootUrl;
		_rootUrl.endsWithSlash = true;
		DavStorage.locks = new DavLockList;
	}

	protected {
		DavResource getOrCreateResource(URL url, out int status) {
			DavResource resource;

			if(exists(url)) {
				resource = getResource(url);
				status = HTTPStatus.ok;
			} else {
				resource = createResource(url);
				status = HTTPStatus.created;
			}

			return resource;
		}

		Path checkPath(Path path) {
			path.endsWithSlash = true;
			return path;
		}
	}

	private {

		bool[string] defaultPropList() {
			bool[string] list;

			list["creationdate:DAV:"] = true;
			list["displayname:DAV:"] = true;
			list["getcontentlength:DAV:"] = true;
			list["getcontenttype:DAV:"] = true;
			list["getetag:DAV:"] = true;
			list["lastmodified:DAV:"] = true;
			list["resourcetype:DAV:"] = true;

			return list;
		}

		bool[string] propList(DavProp document) {
			bool[string] list;

			if(document is null || "allprop" in document["propfind"])
				return defaultPropList;

			auto properties = document["propfind"]["prop"];

			if(properties.length > 0)
				foreach(string key, p; properties)
					list[p.tagName ~ ":" ~ p.namespace] = true;

			return list;
		}
	}

	void registerPlugin(IDavPlugin plugin) {
		plugins ~= plugin;
	}

	bool hasPlugin(string name) {

		foreach(plugin; plugins)
			if(plugin.name == name)
				return true;

		return false;
	}

	void removeResource(URL url, IDavUser user = null) {
		foreach(plugin; plugins)
			if(plugin.exists(url))
				return plugin.removeResource(url, user);

		throw new DavException(HTTPStatus.notFound, "`" ~ url.toString ~ "` not found.");
	}

	DavResource getResource(URL url, IDavUser user = null) {
		foreach(plugin; plugins)
			if(plugin.exists(url))
				return plugin.getResource(url, user);

		throw new DavException(HTTPStatus.notFound, "`" ~ url.toString ~ "` not found.");
	}

	DavResource[] getResources(URL url, ulong depth, IDavUser user = null) {
		DavResource[] list;
		DavResource[] tmpList;

		foreach(plugin; plugins)
			if(plugin.exists(url)) {
				tmpList ~= plugin.getResource(url, user);
				break;
			}

		writeln("tmpList:", tmpList);

		if(depth == 0)
			list ~= tmpList;

		while(tmpList.length > 0 && depth > 0) {

			foreach(resource; tmpList) {
				bool[string] childList = resource.getChildren();

				foreach(string key, bool val; childList) {
					tmpList ~= getResource(URL("http://a/" ~ key), user);
				}
			}

			list ~= tmpList;
			tmpList = [];
			depth--;
		}

		writeln("getResources:", list);

		return list;
	}

	DavResource createCollection(URL url) {
		foreach(plugin; plugins)
			if(plugin.canCreateCollection(url))
				return plugin.createCollection(url);

		throw new DavException(HTTPStatus.methodNotAllowed, "No plugin available.");
	}

	DavResource createResource(URL url) {
		foreach(plugin; plugins)
			if(plugin.canCreateResource(url))
				return plugin.createResource(url);

		throw new DavException(HTTPStatus.methodNotAllowed, "No plugin available.");
	}

	bool exists(URL url) {
		foreach(plugin; plugins)
			if(plugin.exists(url))
				return true;

		return false;
	}

	bool canCreateCollection(URL url) {
		foreach(plugin; plugins)
			if(plugin.canCreateCollection(url))
				return true;

		return false;
	}

	bool canCreateResource(URL url) {
		foreach(plugin; plugins)
			if(plugin.canCreateResource(url))
				return true;

		return false;
	}

	void options(DavRequest request, DavResponse response) {
		DavResource resource = getResource(request.url);

		string path = request.path;

		string[] support;

		foreach(plugin; plugins)
			support ~= plugin.support;

		auto allow = "OPTIONS, GET, HEAD, DELETE, PROPFIND, PUT, PROPPATCH, COPY, MOVE, LOCK, UNLOCK, REPORT";

		response["Accept-Ranges"] = "bytes";
		response["DAV"] = uniq(support).join(",");
		response["Allow"] = allow;
		response["MS-Author-Via"] = "DAV";

		response.flush;
	}

	void propfind(DavRequest request, DavResponse response) {
		bool[string] requestedProperties = propList(request.content);
		DavResource[] list;
		IDavUser user;

		if(userCollection !is null)
			user = userCollection.GetDavUser(request.username);

		list = getResources(request.url, request.depth, user);

		response.setPropContent(list, requestedProperties);

		response.flush;
	}

	void lock(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;

		DavLockInfo currentLock;

		auto resource = getOrCreateResource(request.url, response.statusCode);

		if(request.contentLength != 0) {
			currentLock = DavLockInfo.fromXML(request.content, resource);

			if(currentLock.scopeLock == DavLockInfo.Scope.sharedLock && DavStorage.locks.hasExclusiveLock(resource.fullURL))
				throw new DavException(HTTPStatus.locked, "Already has an exclusive locked.");
			else if(currentLock.scopeLock == DavLockInfo.Scope.exclusiveLock && DavStorage.locks.hasLock(resource.fullURL))
				throw new DavException(HTTPStatus.locked, "Already locked.");
			else if(currentLock.scopeLock == DavLockInfo.Scope.exclusiveLock)
				DavStorage.locks.check(request.url, ifHeader);

			DavStorage.locks.add(currentLock);
		} else if(request.contentLength == 0) {
			string uuid = ifHeader.getAttr("", resource.href);

			auto tmpUrl = resource.url;
			while(currentLock is null) {
				currentLock = DavStorage.locks[tmpUrl.toString, uuid];
				tmpUrl = tmpUrl.parentURL;
			}
		} else if(ifHeader.isEmpty)
			throw new DavException(HTTPStatus.internalServerError, "LOCK body expected.");

		if(currentLock is null)
			throw new DavException(HTTPStatus.internalServerError, "LOCK not created.");

		currentLock.timeout = request.timeout;

		response["Lock-Token"] = "<" ~ currentLock.uuid ~ ">";
		response.mimeType = "application/xml";
		response.content = `<?xml version="1.0" encoding="utf-8" ?><d:prop xmlns:d="DAV:"><d:lockdiscovery> ` ~ currentLock.toString ~ `</d:lockdiscovery></d:prop>`;
		response.flush;
	}

	void unlock(DavRequest request, DavResponse response) {
		auto resource = getResource(request.url);

		DavStorage.locks.remove(resource, request.lockToken);

		response.statusCode = HTTPStatus.noContent;
		response.flush;
	}

	void get(DavRequest request, DavResponse response) {
		DavResource resource = getResource(request.url);

		response["Etag"] = "\"" ~ resource.eTag ~ "\"";
		response["Last-Modified"] = toRFC822DateTimeString(resource.lastModified);
		response["Content-Type"] = resource.contentType;
		response["Content-Length"] = resource.contentLength.to!string;

		if(!request.ifModifiedSince(resource) || !request.ifNoneMatch(resource)) {
			response.statusCode = HTTPStatus.NotModified;
			response.flush;
			return;
		}

		response.flush(resource);
		DavStorage.locks.setETag(resource.url, resource.eTag);
	}

	void head(DavRequest request, DavResponse response) {
		DavResource resource = getResource(request.url);

		response["Etag"] = "\"" ~ resource.eTag ~ "\"";
		response["Last-Modified"] = toRFC822DateTimeString(resource.lastModified);
		response["Content-Type"] = resource.contentType;
		response["Content-Length"] = resource.contentLength.to!string;

		if(!request.ifModifiedSince(resource) || !request.ifNoneMatch(resource)) {
			response.statusCode = HTTPStatus.NotModified;
			response.flush;
			return;
		}

		response.flush;
		DavStorage.locks.setETag(resource.url, resource.eTag);
	}

	void put(DavRequest request, DavResponse response) {
		DavResource resource = getOrCreateResource(request.url, response.statusCode);
		DavStorage.locks.check(request.url, request.ifCondition);

		resource.setContent(request.stream, request.contentLength);

		DavStorage.locks.setETag(resource.url, resource.eTag);

		response.statusCode = HTTPStatus.created;writeln("1");

		response.flush;
	}

	void proppatch(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;
		response.statusCode = HTTPStatus.ok;

		DavStorage.locks.check(request.url, ifHeader);
		DavResource resource = getResource(request.url);

		auto xmlString = resource.propPatch(request.content);

		response.content = xmlString;
		response.flush;
	}

	void mkcol(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;

		if(request.contentLength > 0)
			throw new DavException(HTTPStatus.unsupportedMediaType, "Body must be empty");

		if(!exists(request.url.parentURL))
			throw new DavException(HTTPStatus.conflict, "Missing parent");

		DavStorage.locks.check(request.url, ifHeader);

		response.statusCode = HTTPStatus.created;
		createCollection(request.url);
		response.flush;
	}

	void remove(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;
		auto url = request.url;

		response.statusCode = HTTPStatus.noContent;

		if(url.anchor != "" || request.requestUrl.indexOf("#") != -1)
			throw new DavException(HTTPStatus.conflict, "Missing parent");


		if(!exists(url))
			throw new DavException(HTTPStatus.notFound, "Not found.");

		DavStorage.locks.check(url, ifHeader);

		removeResource(url);

		response.flush;
	}

	void move(DavRequest request, DavResponse response) {
		auto ifHeader = request.ifCondition;
		auto resource = getResource(request.url);

		DavStorage.locks.check(request.url, ifHeader);
		DavStorage.locks.check(request.destination, ifHeader);

		copy(request, response);
		remove(request, response);

		response.flush;
	}

	void copy(DavRequest request, DavResponse response) {
		IDavUser user;

		if(request.username !is null)
			user = userCollection.GetDavUser(request.username);

		URL getDestinationUrl(DavResource source) {
			auto sourceUrl = source.url;
			sourceUrl.host = request.url.host;
			sourceUrl.schema = request.url.schema;
			sourceUrl.port = request.url.port;

			string strSrcUrl = request.url.toString;
			string strDestUrl = request.destination.toString;

			return URL(strDestUrl ~ sourceUrl.toString[strSrcUrl.length..$]);
		}

		void localCopy(DavResource source, DavResource destination) {
			if(source.isCollection) {
				auto list = getResources(request.url, DavDepth.infinity, user);

				foreach(child; list) {
					auto destinationUrl = getDestinationUrl(child);

					if(child.isCollection && !exists(destinationUrl))
						createCollection(getDestinationUrl(child));
					else if(!child.isCollection) {
						HTTPStatus statusCode;
						DavResource destinationChild = getOrCreateResource(getDestinationUrl(child), statusCode);
						destinationChild.setContent(child.stream, child.contentLength);
					}
				}
			} else {
				destination.setContent(source.stream, source.contentLength);
			}
		}

		DavResource source = getResource(request.url);
		DavResource destination;
		HTTPStatus destinationStatus;

		DavStorage.locks.check(request.destination, request.ifCondition);

		if(!exists(request.destination.parentURL))
			throw new DavException(HTTPStatus.conflict, "Conflict. `" ~ request.destination.parentURL.toString ~ "` does not exist.");

		if(!request.overwrite && exists(request.destination))
			throw new DavException(HTTPStatus.preconditionFailed, "Destination already exists.");

		response.statusCode = HTTPStatus.created;
		if(exists(request.destination)) {
			destination = getResource(request.destination);
		}

		response.statusCode = HTTPStatus.created;

		URL destinationUrl = request.destination;

		if(destination !is null && destination.isCollection && !source.isCollection) {
			destinationUrl.path = destinationUrl.path ~ source.url.path.head;
			destination = null;
			response.statusCode = HTTPStatus.noContent;
		}

		if(destination is null) {
			if(source.isCollection)
				destination = createCollection(destinationUrl);
			else
				destination = createResource(destinationUrl);
		}

		localCopy(source, destination);

		response.flush;
	}
}

/// Hook vibe.d requests to the right DAV method
HTTPServerRequestDelegate serveDav(T : IDav)(T dav) {
	void callback(HTTPServerRequest req, HTTPServerResponse res)
	{
		try {
			debug {
				writeln("\n\n\n");

				writeln("==========================================================");
				writeln(req.fullURL);
				writeln("Method: ", req.method, "\n");

				foreach(key, val; req.headers)
					writeln(key, ": ", val);
			}

			DavRequest request = DavRequest(req);
			DavResponse response = DavResponse(res);

			if(req.method == HTTPMethod.OPTIONS) {
				dav.options(request, response);
			} else if(req.method == HTTPMethod.PROPFIND) {
				dav.propfind(request, response);
			} else if(req.method == HTTPMethod.HEAD) {
				dav.head(request, response);
			} else if(req.method == HTTPMethod.GET) {
				dav.get(request, response);
			} else if(req.method == HTTPMethod.PUT) {
				dav.put(request, response);
			} else if(req.method == HTTPMethod.PROPPATCH) {
				dav.proppatch(request, response);
			} else if(req.method == HTTPMethod.LOCK) {
				dav.lock(request, response);
			} else if(req.method == HTTPMethod.UNLOCK) {
				dav.unlock(request, response);
			} else if(req.method == HTTPMethod.MKCOL) {
				dav.mkcol(request, response);
			} else if(req.method == HTTPMethod.DELETE) {
				dav.remove(request, response);
			} else if(req.method == HTTPMethod.COPY) {
				dav.copy(request, response);
			} else if(req.method == HTTPMethod.MOVE) {
				dav.move(request, response);
			} else {
				res.statusCode = HTTPStatus.notImplemented;
				res.writeBody("", "text/plain");
			}
		} catch(DavException e) {
			writeln("ERROR:",e.status.to!int, "(", e.status, ") - ", e.msg);

			res.statusCode = e.status;
			res.writeBody(e.msg, e.mime);
		}

		debug {
			writeln("\nSUCCESS:", res.statusCode.to!int, "(", res.statusCode, ")");
		}
	}

	return &callback;
}
