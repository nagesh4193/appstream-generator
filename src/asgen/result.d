/*
 * Copyright (C) 2016-2017 Matthias Klumpp <matthias@tenstral.net>
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

module asgen.result;

import std.stdio;
import std.string;
import std.array : empty;
import std.conv : to;
import std.json;
import appstream.Component;

import asgen.containers : HashMap;
import asgen.hint;
import asgen.utils : buildCptGlobalID;
import asgen.backends.interfaces;
import asgen.config : Config;


/**
 * Helper function for GeneratorResult.finalize()
 */
extern(C)
int evaluateCustomEntry (void *keyPtr, void *value, void *userData)
{
    auto key = (cast(const(char)*) keyPtr).fromStringz;
    auto conf = *cast(Config*) userData;

    if (key in conf.allowedCustomKeys)
        return false; // FALSE, do not delete

    // remove invalid key
    return true;
}

/**
 * Holds metadata generator result(s) and issue hints
 * for a single package.
 */
final class GeneratorResult
{

private:
    Component[string] cpts;
    string[Component] cptGCID;
    HashMap!(string, string) mdataHashes;
    HashMap!(string, GeneratorHint[]) hints;

public:
    immutable string pkid;
    immutable string pkgname;
    Package pkg;


    this (Package pkg)
    {
        this.pkid = pkg.id;
        this.pkgname = pkg.name;
        this.pkg = pkg;
    }

    @safe
    bool packageIsIgnored () pure
    {
        return (cpts.length == 0) && (hints.length == 0);
    }

    @safe
    Component getComponent (string id) pure
    {
        auto ptr = (id in cpts);
        if (ptr is null)
            return null;
        return *ptr;
    }

    @trusted
    Component[] getComponents () pure
    {
        return cpts.values ();
    }

    @trusted
    bool isIgnored (Component cpt)
    {
        return getComponent (cpt.getId ()) is null;
    }

    @trusted
    void updateComponentGCID (Component cpt, string data)
    {
        import std.digest.md;

        auto cid = cpt.getId ();
        if (data.empty) {
            cptGCID[cpt] = buildCptGlobalID (cid, "???-NO_CHECKSUM-???");
            return;
        }

        auto oldHashP = (cid in mdataHashes);
        string oldHash = "";
        if (oldHashP !is null)
            oldHash = *oldHashP;

        auto hash = md5Of (oldHash ~ data);
        auto checksum = toHexString (hash);
        auto newHash = to!string (checksum);

        mdataHashes[cid] = newHash;
        cptGCID[cpt] = buildCptGlobalID (cid, newHash);
    }

    @trusted
    void addComponent (Component cpt, string data = "")
    {
        string cid = cpt.getId;
        if (cid.empty)
            throw new Exception ("Can not add component from '%s' without ID to results set: %s".format (this.pkid, cpt.toString));

        // web applications, operating systems, repositories
        // and component-removal merges don't (need to) have a package name set
        if (cpt.getKind != ComponentKind.WEB_APP &&
            cpt.getKind != ComponentKind.OPERATING_SYSTEM &&
            cpt.getMergeKind != MergeKind.REMOVE_COMPONENT) {
            if (pkg.kind != PackageKind.FAKE)
                cpt.setPkgnames ([this.pkgname]);
        }

        cpts[cid] = cpt;
        updateComponentGCID (cpt, data);
    }

    @safe
    void dropComponent (string cid) pure
    {
        auto cpt = getComponent (cid);
        if (cpt is null)
            return;
        cpts.remove (cid);
        cptGCID.remove (cpt);
    }

    /**
     * Add an issue hint to this result.
     * Params:
     *      id = The component-id or component itself this tag is assigned to.
     *      tag    = The hint tag.
     *      params = Dictionary of parameters to insert into the issue report.
     * Returns:
     *      True if the hint did not cause the removal of the component, False otherwise.
     **/
    @trusted
    bool addHint (T) (T id, string tag, string[string] params)
        if (is(T == string) || is(T == Component) || is(T == typeof(null)))
    {
        static if (is(T == string)) {
            immutable cid = id;
        } else {
            static if (is(T == typeof(null)))
                immutable cid = "general";
            else
                immutable cid = id.getId ();
        }

        auto hint = GeneratorHint (tag, cid);
        hint.setVars (params);
        if (cid in hints)
            hints[cid] ~= hint;
        else
            hints[cid] = [hint];

        // we stop dealing with this component when we encounter a fatal
        // error.
        if (hint.isError) {
            dropComponent (cid);
            return false;
        }

        return true;
    }

    /**
     * Add an issue hint to this result.
     * Params:
     *      id = The component-id or component itself this tag is assigned to.
     *      tag = The hint tag.
     *      msg = An error message to add to the report.
     * Returns:
     *      True if the hint did not cause the removal of the component, False otherwise.
     **/
    @safe
    bool addHint (T) (T id, string tag, string msg = null)
    {
        string[string] vars;
        if (msg !is null)
            vars = ["msg": msg];
        return addHint (id, tag, vars);
    }

    /**
     * Create JSON metadata for the hints found for the package
     * associacted with this GeneratorResult.
     */
    string hintsToJson ()
    {
        if (hints.length == 0)
            return null;

        // is this really the only way you can set a type for JSONValue?
        auto map = JSONValue (["null": 0]);
        map.object.remove ("null");

        foreach (cid; hints.byKey) {
            auto cptHints = hints[cid];
            auto hintNodes = JSONValue ([0, 0]);
            hintNodes.array = [];
            foreach (ref hint; cptHints) {
                hintNodes.array ~= hint.toJsonNode ();
            }

            map.object[cid] = hintNodes;
        }

        auto root = JSONValue (["package": JSONValue (pkid), "hints": map]);
        return root.toJSON (true);
    }

    /**
     * Drop invalid components and components with errors.
     */
    void finalize ()
    {
        auto conf = Config.get ();

        // we need to duplicate the associative array, because the addHint() function
        // may remove entries from "cpts", breaking our foreach loop.
        foreach (cpt; cpts.dup.byValue) {
            immutable ckind = cpt.getKind;
            cpt.setActiveLocale ("C");

            if (ckind == ComponentKind.UNKNOWN)
                if (!addHint (cpt, "metainfo-unknown-type"))
                    continue;

            if (cpt.getMergeKind == MergeKind.NONE) {
                // only perform these checks if we don't have a merge-component
                // (which is by definition incomplete and only is required to have its ID present)

                if (cpt.getPkgnames.empty) {
                    // no packages are associated with this component

                    if (ckind != ComponentKind.WEB_APP &&
                        ckind != ComponentKind.OPERATING_SYSTEM &&
                        ckind != ComponentKind.REPOSITORY) {
                            // this component is not allowed to have no installation candidate
                            if (!cpt.hasBundle) {
                                if (!addHint (cpt, "no-install-candidate"))
                                    continue;
                            }
                    }
                } else {
                    // packages are associated with this component

                    if (pkg.kind == PackageKind.FAKE) {
                        import std.algorithm : canFind;
                        import asgen.config : EXTRA_METAINFO_FAKE_PKGNAME;

                        if (cpt.getPkgnames.canFind (EXTRA_METAINFO_FAKE_PKGNAME)) {
                            if (!addHint (cpt, "component-fake-package-association"))
                                continue;
                        }
                    }

                    // strip out any release artifact information of components that have a
                    // distribution package association
                    if (!conf.feature.propagateMetaInfoArtifacts) {
                        import appstream.c.functions : as_release_get_artifacts;
                        import glib.c.functions : g_ptr_array_set_size;

                        auto relArr = cpt.getReleases;
                        for (uint i = 0; i < relArr.len; i++) {
                            auto releasePtr = cast (AsRelease*) relArr.index (i);
                            g_ptr_array_set_size (as_release_get_artifacts (releasePtr), 0);
                        }
                    }
                }

                if (cpt.getName.empty)
                    if (!addHint (cpt, "metainfo-no-name"))
                        continue;

                if (cpt.getSummary.empty)
                    if (!addHint (cpt, "metainfo-no-summary"))
                        continue;

                // ensure that everything that should have an icon has one
                if (cpt.getIcons.len == 0) {
                    if (ckind == ComponentKind.DESKTOP_APP) {
                        if (!addHint (cpt, "gui-app-without-icon"))
                            continue;
                    } else if (ckind == ComponentKind.WEB_APP) {
                        if (!addHint (cpt, "web-app-without-icon"))
                            continue;
                    } else if (ckind == ComponentKind.FONT) {
                        if (!addHint (cpt, "font-without-icon"))
                            continue;
                    } else if (ckind == ComponentKind.OPERATING_SYSTEM) {
                        if (!addHint (cpt, "os-without-icon"))
                            continue;
                    }
                }

                // desktop and web apps get extra treatment (more validation, addition of fallback long-description)
                if (ckind == ComponentKind.DESKTOP_APP || ckind == ComponentKind.WEB_APP) {
                    // desktop-application components are required to have a category
                    if (cpt.getCategories.len <= 0)
                        if (!addHint (cpt, "no-valid-category"))
                            continue;

                    // inject package descriptions, if needed
                    auto flags = cpt.getValueFlags;
                    cpt.setValueFlags (flags | AsValueFlags.NO_TRANSLATION_FALLBACK);

                    cpt.setActiveLocale ("C");
                    if (cpt.getDescription.empty) {
                        // component doesn't have a long description, add one from
                        // the packaging.
                        auto desc_added = false;
                        foreach (ref lang, ref desc; pkg.description) {
                                cpt.setDescription (desc, lang);
                                desc_added = true;
                        }

                        if (conf.feature.warnNoMetaInfo) {
                            if (!addHint (cpt, "no-metainfo"))
                                continue;
                        }

                        if (desc_added) {
                            if (!conf.feature.warnNoMetaInfo) {
                                if (!addHint (cpt, "description-from-package"))
                                    continue;
                            }
                        } else {
                            import asgen.bindings.appstream_utils : componentKindToString;

                            if ((ckind == ComponentKind.DESKTOP_APP) ||
                                (ckind == ComponentKind.CONSOLE_APP) ||
                                (ckind == ComponentKind.WEB_APP)) {
                                    if (!addHint (cpt, "description-missing", ["kind": componentKindToString (ckind)]))
                                    continue;
                            }
                        }
                    }

                    // check if we can add a launchable here
                    if (ckind == ComponentKind.DESKTOP_APP) {
                        if ((cpt.getLaunchable (LaunchableKind.DESKTOP_ID) is null) && (cpt.getId.endsWith (".desktop"))) {
                            import appstream.Launchable : Launchable, LaunchableKind;
                            auto launch = new Launchable;
                            launch.setKind (LaunchableKind.DESKTOP_ID);
                            launch.addEntry (cpt.getId);
                            cpt.addLaunchable (launch);
                        }
                    }
                } // end of checks for desktop/web apps

            } // end of check for non-merge components

            // finally, filter custom tags
            auto customHashTable = cpt.getCustom ();
            immutable noCustomKeysAllowed = conf.allowedCustomKeys.length == 0;
            if (customHashTable.size > 0) {
                if (noCustomKeysAllowed) {
                    // if we don't allow any custom keys, we can delete them faster
                    customHashTable.removeAll ();
                    continue;
                }

                // filter the custom values
                customHashTable.foreachRemove (&evaluateCustomEntry, &conf);
            }

        } // end of components loop
    }

    /**
     * Return the number of components we've found.
     **/
    @safe
    ulong componentsCount () pure
    {
        return cpts.length;
    }

    /**
     * Return the number of hints that have been emitted.
     **/
    @safe
    ulong hintsCount () pure
    {
        return hints.length;
    }

    @safe
    string gcidForComponent (Component cpt) pure
    {
        auto cgp = (cpt in cptGCID);
        if (cgp is null)
            return null;
        return *cgp;
    }

    @trusted
    string[] getGCIDs () pure
    {
        return cptGCID.values ();
    }

}

unittest
{
    import asgen.backends.dummy.dummypkg;
    writeln ("TEST: ", "GeneratorResult");

    auto pkg = new DummyPackage ("foobar", "1.0", "amd64");
    auto res = new GeneratorResult (pkg);

    auto vars = ["rainbows": "yes", "unicorns": "no", "storage": "towel"];
    res.addHint ("org.freedesktop.foobar.desktop", "just-a-unittest", vars);
    res.addHint ("org.freedesktop.awesome-bar.desktop", "metainfo-chocolate-missing", "Nothing is good without chocolate. Add some.");
    res.addHint ("org.freedesktop.awesome-bar.desktop", "metainfo-does-not-frobnicate", "Frobnicate functionality is missing.");

    writeln (res.hintsToJson ());
}
