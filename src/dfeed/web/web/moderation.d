﻿/*  Copyright (C) 2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018  Vladimir Panteleev <vladimir@thecybershadow.net>
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU Affero General Public License as
 *  published by the Free Software Foundation, either version 3 of the
 *  License, or (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU Affero General Public License for more details.
 *
 *  You should have received a copy of the GNU Affero General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

/// Moderation tools.
module dfeed.web.web.moderation;

import std.array;
import std.exception : enforce;
import std.file : exists, read, rename;
import std.format : format;
import std.regex : match;
import std.stdio : File;
import std.string : splitLines, indexOf;

import ae.net.http.common : HttpRequest;
import ae.net.ietf.url : UrlParameters;
import ae.sys.log : Logger, fileLogger;
import ae.utils.json : toJson;
import ae.utils.regex : escapeRE;
import ae.utils.text : splitAsciiLines;

import dfeed.database : query;
import dfeed.message : Rfc850Post;
import dfeed.sinks.cache : dbVersion;
import dfeed.site : site;
import dfeed.web.moderation : banned, saveBanList;
import dfeed.web.posting : PostProcess;
import dfeed.web.web : getPost, userSettings;

string findPostingLog(string id)
{
	if (id.match(`^<[a-z]{20}@` ~ site.host.escapeRE() ~ `>`))
	{
		auto post = id[1..21];
		version (Windows)
			auto logs = dirEntries("logs", "*PostProcess-" ~ post ~ ".log", SpanMode.depth).array;
		else
		{
			import std.process;
			auto result = execute(["find", "logs/", "-name", "*PostProcess-" ~ post ~ ".log"]); // This is MUCH faster than dirEntries.
			enforce(result.status == 0, "find error");
			auto logs = splitLines(result.output);
		}
		if (logs.length == 1)
			return logs[0];
	}
	return null;
}

void deletePostImpl(string messageID, string reason, string userName, bool ban, void delegate(string) feedback)
{
	auto post = getPost(messageID);
	enforce(post, "Post not found");

	auto deletionLog = fileLogger("Deleted");
	scope(exit) deletionLog.close();
	scope(failure) deletionLog("An error occurred");
	deletionLog("User %s is deleting post %s (%s)".format(userName, post.id, reason));
	foreach (line; post.message.splitAsciiLines())
		deletionLog("> " ~ line);

	foreach (string[string] values; query!"SELECT * FROM `Posts` WHERE `ID` = ?".iterate(post.id))
		deletionLog("[Posts] row: " ~ values.toJson());
	foreach (string[string] values; query!"SELECT * FROM `Threads` WHERE `ID` = ?".iterate(post.id))
		deletionLog("[Threads] row: " ~ values.toJson());

	if (ban)
	{
		banPoster(userName, post.id, reason);
		deletionLog("User was banned for this post.");
		feedback("User banned.<br>");
	}

	query!"DELETE FROM `Posts` WHERE `ID` = ?".exec(post.id);
	query!"DELETE FROM `Threads` WHERE `ID` = ?".exec(post.id);

	dbVersion++;
	feedback("Post deleted.");
}

// Create logger on demand, to avoid creating empty log files
Logger banLog;
void needBanLog() { if (!banLog) banLog = fileLogger("Banned"); }

void banPoster(string who, string id, string reason)
{
	needBanLog();
	banLog("User %s is banning poster of post %s (%s)".format(who, id, reason));
	auto fn = findPostingLog(id);
	enforce(fn && fn.exists, "Can't find posting log");

	auto pp = new PostProcess(fn);
	string[] keys;
	keys ~= pp.ip;
	keys ~= pp.draft.clientVars.get("secret", null);
	foreach (cookie; pp.headers.get("Cookie", null).split("; "))
	{
		auto p = cookie.indexOf("=");
		if (p<0) continue;
		auto name = cookie[0..p];
		auto value = cookie[p+1..$];
		if (name == "dfeed_secret" || name == "dfeed_session")
			keys ~= value;
	}

	foreach (key; keys)
		if (key.length)
		{
			if (key in banned)
				banLog("Key already known: " ~ key);
			else
			{
				banned[key] = reason;
				banLog("Adding key: " ~ key);
			}
		}

	saveBanList();
	banLog("Done.");
}

/// If the user is banned, returns the ban reason.
/// Otherwise, returns null.
string banCheck(string ip, HttpRequest request)
{
	string[] keys = [ip];
	foreach (cookie; request.headers.get("Cookie", null).split("; "))
	{
		auto p = cookie.indexOf("=");
		if (p<0) continue;
		auto name = cookie[0..p];
		auto value = cookie[p+1..$];
		if (name == "dfeed_secret" || name == "dfeed_session")
			if (value.length)
				keys ~= value;
	}
	string secret = userSettings.secret;
	if (secret.length)
		keys ~= secret;

	string bannedKey = null, reason = null;
	foreach (key; keys)
		if (key in banned)
		{
			bannedKey = key;
			reason = banned[key];
			break;
		}

	if (!bannedKey)
		return null;

	needBanLog();
	banLog("Request from banned user: " ~ request.resource);
	foreach (name, value; request.headers)
		banLog("* %s: %s".format(name, value));

	banLog("Matched on: %s (%s)".format(bannedKey, reason));
	bool propagated;
	foreach (key; keys)
		if (key !in banned)
		{
			banLog("Propagating: %s -> %s".format(bannedKey, key));
			banned[key] = "%s (propagated from %s)".format(reason, bannedKey);
			propagated = true;
		}

	if (propagated)
		saveBanList();

	return reason;
}
