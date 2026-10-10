"""Disposable system-smoke apps; declare only Fileto validation document types."""
import pathlib
import plistlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
source = root / "fixture.m"
source.write_text(r'''
#import <AppKit/AppKit.h>
@interface FixtureDelegate : NSObject <NSApplicationDelegate>
@end
@implementation FixtureDelegate
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    NSURL *bundle = NSBundle.mainBundle.bundleURL;
    NSString *output = NSProcessInfo.processInfo.environment[@"FILETO_FIXTURE_OUTPUT"];
    NSURL *directory = output ? [NSURL fileURLWithPath:output isDirectory:YES] : [bundle URLByDeletingLastPathComponent];
    NSURL *marker = [directory URLByAppendingPathComponent:
        [[bundle.lastPathComponent stringByDeletingPathExtension] stringByAppendingString:@".opened.json"]];
    NSMutableArray *paths = [NSMutableArray array];
    for (NSURL *url in urls) { [paths addObject:url.path]; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:paths options:0 error:nil];
    [data writeToURL:marker atomically:YES];
    // Keep the process alive until the harness checks Launch Services' returned
    // NSRunningApplication identity and the delivered file, then terminates it.
}
@end
int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        FixtureDelegate *delegate = [FixtureDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
''')
for name in ("First", "Second"):
    app = root / f"{name}.app" / "Contents"
    (app / "MacOS").mkdir(parents=True)
    subprocess.run(["xcrun", "clang", "-mmacosx-version-min=13.0", "-fobjc-arc", "-framework", "AppKit", str(source), "-o", str(app / "MacOS" / "Fixture")], check=True)
    declarations = []
    for suffix in ("one", "two"):
        declarations.append({
            "UTTypeIdentifier": f"com.fileto.validation.{suffix}",
            "UTTypeDescription": f"Fileto validation {suffix}",
            "UTTypeConformsTo": ["public.data"],
            "UTTypeTagSpecification": {"public.filename-extension": [f"filetovalidation{suffix}"]},
        })
    info = {
        "CFBundleIdentifier": f"com.fileto.validation.{name.lower()}",
        "CFBundleName": name,
        "CFBundleExecutable": "Fixture",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
        "NSPrincipalClass": "NSApplication",
        "LSUIElement": True,
        "LSMinimumSystemVersion": "13.0",
        "UTExportedTypeDeclarations": declarations,
        "CFBundleDocumentTypes": [{
            "CFBundleTypeName": "Fileto validation files",
            "CFBundleTypeRole": "Editor",
            "LSHandlerRank": "Default",
            "LSItemContentTypes": [entry["UTTypeIdentifier"] for entry in declarations],
        }],
    }
    with (app / "Info.plist").open("wb") as handle:
        plistlib.dump(info, handle)
