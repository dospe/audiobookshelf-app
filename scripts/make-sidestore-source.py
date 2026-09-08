#!/usr/bin/env python3
"""Write a SideStore / AltStore source (AltSource) JSON for one build of the iOS app.

Run by .github/workflows/build-ios.yml after the unsigned IPA is packaged. The
feed is attached to the "latest-ios" GitHub release next to the IPA, so
SideStore can offer every new master build as an update - see
docs/ios-sideload.md.

The format follows https://faq.altstore.io/developers/make-a-source (the
"versions" array) and also carries the legacy top-level version fields for
older parsers. SideStore rejects sources carrying "marketplaceID" (notarized
AltStore PAL apps), so that field must never appear here.
"""
import argparse
import json
import sys

BUNDLE_IDENTIFIER = "com.audiobookshelf.app"


def build_source(args):
    version_notes = f"Build {args.build_number} of master ({args.commit}), built {args.date}."
    app = {
        "name": "Audiobookshelf",
        "bundleIdentifier": BUNDLE_IDENTIFIER,
        "developerName": args.developer,
        "subtitle": "Audiobooks, podcasts and ebooks with read aloud",
        "localizedDescription": (
            "Test build of the audiobookshelf-app fork with the native read aloud (TTS) "
            "player for ebooks. Unsigned IPA - SideStore signs it with your Apple ID."
        ),
        "iconURL": args.icon_url,
        "category": "entertainment",
        "versions": [
            {
                "version": args.version,
                "buildVersion": args.build_number,
                "date": args.date,
                "localizedDescription": version_notes,
                "downloadURL": args.download_url,
                "size": args.size,
                "sha256": args.sha256,
                "minOSVersion": "14.0",
            }
        ],
        # Legacy single-version fields, read by parsers that predate "versions"
        "version": args.version,
        "versionDate": args.date,
        "versionDescription": version_notes,
        "downloadURL": args.download_url,
        "size": args.size,
        "appPermissions": {"entitlements": [], "privacy": {}},
    }
    return {
        "name": "Audiobookshelf (dospe)",
        "identifier": "com.github.dospe.audiobookshelf-app",
        "subtitle": "Test builds of the audiobookshelf-app fork",
        "description": (
            "Unsigned iOS builds of the master branch of dospe/audiobookshelf-app. "
            "Every push to master replaces the build in this source."
        ),
        "iconURL": args.icon_url,
        "website": args.website,
        "apps": [app],
        "news": [],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString of the IPA")
    parser.add_argument("--build-number", required=True, help="CFBundleVersion of the IPA")
    parser.add_argument("--date", required=True, help="ISO 8601 build date")
    parser.add_argument("--commit", required=True, help="short git sha")
    parser.add_argument("--download-url", required=True, help="direct URL of the IPA on the release")
    parser.add_argument("--size", required=True, type=int, help="IPA size in bytes")
    parser.add_argument("--sha256", required=True, help="IPA sha256 hex digest")
    parser.add_argument("--icon-url", required=True, help="PNG app icon URL")
    parser.add_argument("--website", required=True, help="repository URL")
    parser.add_argument("--developer", default="dospe")
    args = parser.parse_args()
    json.dump(build_source(args), sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
