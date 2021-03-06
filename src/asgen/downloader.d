/*
 * Copyright (C) 2019-2020 Matthias Klumpp <matthias@tenstral.net>
 *
 * Licensed under the GNU Lesser General Public License Version 3
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the license, or
 * (at your option) any later version.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this software.  If not, see <http://www.gnu.org/licenses/>.
 */

module asgen.downloader;
@safe:

import std.stdio : File;
import std.typecons : Nullable;
import std.datetime : SysTime, Clock, parseRFC822DateTime, DateTimeException;
import std.array : appender, empty;
import std.path : buildPath, dirName, buildNormalizedPath;
import std.algorithm : startsWith;
import asgen.logging;
static import std.file;

private import asgen.bindings.soup;
private import asgen.utils;
private import asgen.config : Config;
private import gobject.c.functions;
private import gio.InputStream : GInputStream;
private import gio.c.functions : g_input_stream_read;
private import std.string : format, toStringz, fromStringz;

class DownloadException : Exception
{
    @safe pure nothrow
    this(string msg,
         string file = __FILE__,
         size_t line = __LINE__,
         Throwable next = null)
    {
        super (msg, file, line, next);
    }
}

/**
 * Download data via HTTP. Based on libsoup.
 */
final class Downloader
{

private:
    SoupSession *session;

    // thread local instance
    static Downloader instance_;

public:

    static Downloader get () @trusted
    {
        if (instance_ is null)
           instance_ = new Downloader;
        return instance_;
    }

    this () @trusted
    {
        session = soup_session_new_with_options (SOUP_SESSION_USER_AGENT.toStringz,
                                                 "appstream-generator".toStringz,
                                                 SOUP_SESSION_TIMEOUT.toStringz,
                                                 40,
                                                 null);
        if (session is null) {
            throw new Exception ("Unable to set up networking support!");
            assert (0);
        }

        // set custom SSL CA file, if we have one
        immutable caInfo = Config.get.caInfo;
        if (!caInfo.empty) {
            g_object_set (session,
                          SOUP_SESSION_SSL_CA_FILE.toStringz,
                          caInfo.toStringz,
                          null);
        }

        // set default proxy resolver
        soup_session_add_feature_by_type (session,
                                          soup_proxy_resolver_default_get_type ());
    }

    ~this () @trusted
    {
        g_object_unref (session);
    }

    private auto downloadInternal (const string url, ref Nullable!SysTime lastModified, uint maxTryCount = 3) @trusted
    in { assert (url.isRemote); }
    do
    {
        auto spUri = soup_uri_new (url.toStringz);
        scope (exit) soup_uri_free (spUri);

        // check if our URI is valid for HTTP(S)
        const uriScheme = soup_uri_get_scheme (spUri).fromStringz;
        if ((spUri is null) ||
            (uriScheme != "http" && uriScheme != "https") ||
            ((spUri.host is null) || (spUri.path is null))) {
                if (uriScheme == "ftp")
                    throw new DownloadException ("Downloads via FTP are not supported. Url '%s' is invalid.".format (url));
                else
                    throw new DownloadException ("The URL '%s' is no valid HTTP(S) URL!".format (url));
        }

        // set up message
        auto msg = soup_message_new_from_uri (SOUP_METHOD_GET, spUri);
        if (msg is null)
            throw new DownloadException ("Unable to set up GET request for URL '%s'".format (url));
        scope (exit) g_object_unref (msg);

        if (maxTryCount == 0)
            maxTryCount = 1;

        // send message, retry a few times
        logDebug ("Downloading '%s'", url);
        GInputStream *stream;
        for (int tryNo = 1; tryNo <= maxTryCount; tryNo++) {
            stream = soup_session_send (session, msg, null, null);
            scope (failure) { if (stream !is null) g_object_unref (stream); }
            immutable statusCode = msg.statusCode;

            if ((statusCode >  0) && (statusCode < 100)) {
                // transport error

                if (tryNo != maxTryCount) {
                    if (stream !is null)
                        g_object_unref (stream);
                    logDebug ("Download of '%s' failed: Connection issue %s (%s), retrying (try %s/%s)",
                              url, statusCode, soup_status_get_phrase (statusCode).fromStringz, tryNo + 1, maxTryCount);
                    continue;
                }
                throw new DownloadException ("Failed to retrieve '%s': Connection issue %s (%s)".format (url, statusCode, soup_status_get_phrase (statusCode).fromStringz));
            } else if (statusCode != 200) {
                // any other HTTP status that isn't OK
                if (tryNo != maxTryCount) {
                    if (stream !is null)
                        g_object_unref (stream);
                    logDebug ("Download of '%s' failed: HTTP %s (%s), retrying (try %s/%s)",
                              url, statusCode, soup_status_get_phrase (statusCode).fromStringz, tryNo + 1, maxTryCount);
                    continue;
                }
                throw new DownloadException ("Failed to retrieve '%s' (HTTP %s: %s)".format (url, statusCode, soup_status_get_phrase (statusCode).fromStringz));
            }

            // everything was fine at this point, no need to retry download
            break;
        }

        if (stream is null)
            throw new DownloadException ("Unable to get data stream for download of '%s'.".format (url));

        const lastModifiedStr = soup_message_headers_get (msg.responseHeaders, "last-modified".toStringz).fromStringz;
        if (!lastModifiedStr.empty) {
            try {
                lastModified = parseRFC822DateTime (lastModifiedStr);
            } catch (DateTimeException dtE) {
                logDebug ("Received invalid `last-modified` time '%s' from '%s': %s", lastModifiedStr, url, dtE.msg);
                lastModified.nullify ();
            }
        }

        return stream;
    }

    immutable(Nullable!SysTime) download (const string url, ref File dFile, const uint maxTryCount = 3) @trusted
    do
    {
        Nullable!SysTime ret;
        auto stream = downloadInternal (url, ret, maxTryCount);
        scope(exit) g_object_unref (stream);

        ptrdiff_t len;
        do {
            ubyte[GENERIC_BUFFER_SIZE] buffer;

            len = g_input_stream_read (stream, cast(void*)buffer.ptr, cast(size_t)buffer.length, null, null);
            if (len > 0)
                dFile.rawWrite (buffer[0..len]);
        } while (len > 0);

        return ret;
    }

    ubyte[] download (const string url, const uint tryCount = 3) @trusted
    {
        Nullable!SysTime lastModifiedTime;
        auto stream = downloadInternal (url, lastModifiedTime, tryCount);
        scope(exit) g_object_unref (stream);

        auto result = appender!(ubyte[]);
        ptrdiff_t len;
        do {
            ubyte[GENERIC_BUFFER_SIZE] buffer;

            len = g_input_stream_read (stream, cast(void*)buffer.ptr, cast(size_t)buffer.length, null, null);
            result ~= buffer[0..len];
        } while (len > 0);

        return result.data;
    }

    /**
     * Download `url` to `dest`.
     *
     * Params:
     *      url = The URL to download.
     *      dest = The location for the downloaded file.
     *      maxTryCount = Number of times to attempt the download.
     */
    void downloadFile (const string url, const string dest, const uint maxTryCount = 3) @trusted
    out { assert (std.file.exists (dest)); }
    do
    {
        import std.file : exists, remove, mkdirRecurse, setTimes;

        if (dest.exists) {
            logDebug ("File '%s' already exists, re-download of '%s' skipped.", dest, url);
            return;
        }

        mkdirRecurse (dest.dirName);

        auto f = File (dest, "wb");
        scope (failure) remove (dest);

        auto time = download (url, f, maxTryCount);

        f.close ();
        if (!time.isNull)
            setTimes (dest, Clock.currTime, time.get);
    }

    /**
     * Download `url` and return a string with its contents.
     *
     * Params:
     *      url = The URL to download.
     *      maxTryCount = Number of times to retry on timeout.
     */
    string downloadText (const string url, const uint maxTryCount = 3) @trusted
    {
        import std.conv : to;
        const data = download (url, maxTryCount);
        return (cast(char[])data).to!string;
    }

    /**
     * Download `url` and return a string array of lines.
     *
     * Params:
     *      url = The URL to download.
     *      maxTryCount = Number of times to retry on timeout.
     */
    string[] downloadTextLines (const string url, const uint maxTryCount = 3) @trusted
    {
        import std.string : splitLines;
        return downloadText (url, maxTryCount).splitLines;
    }

}

@trusted
unittest
{
    import std.stdio : writeln;
    import std.exception : assertThrown;
    import std.file : remove, readText;
    import std.process : environment;
    asgen.logging.setVerbose (true);

    writeln ("TEST: ", "Downloader");

    if (environment.get("ASGEN_TESTS_NO_NET", "no") != "no") {
        writeln ("I: NETWORK DEPENDENT TESTS SKIPPED. (explicitly disabled via `ASGEN_TESTS_NO_NET`)");
        return;
    }

    immutable urlFirefoxDetectportal = "https://detectportal.firefox.com/";
    auto dl = new Downloader;
    string detectPortalRes;
    try {
        detectPortalRes = dl.downloadText (urlFirefoxDetectportal);
    } catch (Exception e) {
        writeln ("W: NETWORK DEPENDENT TESTS SKIPPED. (automatically, no network detected: ", e.msg, ")");
        return;
    }
    writeln ("I: Running network-dependent tests.");
    assert (detectPortalRes == "success\n");

    // check if a downloaded file contains the right contents
    immutable firefoxDetectportalFname = "/tmp/asgen-test.ffdp" ~ randomString (4);
    scope(exit) firefoxDetectportalFname.remove ();
    dl.downloadFile (urlFirefoxDetectportal, firefoxDetectportalFname);
    assert (readText (firefoxDetectportalFname) == "success\n");


    // download a bigger chunk of data without error
    immutable debianOrgFname = "/tmp/asgen-test.do" ~ randomString (4);
    scope(exit) debianOrgFname.remove ();
    dl.downloadFile ("https://debian.org", debianOrgFname);

    // fail when attempting to download a nonexistent file
    assertThrown!DownloadException (dl.downloadFile ("https://appstream.debian.org/nonexistent", "/tmp/asgen-dltest" ~ randomString (4), 2));

    // check if HTTP --> HTTPS redirects, like done on mozilla.org, work
    dl.downloadFile ("http://mozilla.org", "/tmp/asgen-test.mozilla" ~ randomString (4), 1);
}
