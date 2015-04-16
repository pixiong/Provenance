//
//  PVGameImporter.m
//  Provenance
//
//  Created by James Addyman on 01/04/2015.
//  Copyright (c) 2015 James Addyman. All rights reserved.
//

#import "PVGameImporter.h"
#import "PVEmulatorConfiguration.h"
#import "PVGame.h"
#import "OESQLiteDatabase.h"
#import "NSFileManager+Hashing.h"
#import "PVMediaCache.h"
#import <Realm/Realm.h>

@interface PVGameImporter ()

@property (nonatomic, strong) dispatch_queue_t serialImportQueue;
@property (nonatomic, strong) NSDictionary *systemToPathMap;
@property (nonatomic, strong) NSDictionary *romToSystemMap;
@property (nonatomic, assign) BOOL encounteredConflicts;

@end

@implementation PVGameImporter

- (instancetype)initWithCompletionHandler:(PVGameImporterCompletionHandler)completionHandler
{
    if ((self = [super init]))
    {
        self.serialImportQueue = dispatch_queue_create("com.jamsoftonline.provenance.serialImportQueue", DISPATCH_QUEUE_SERIAL);
        self.systemToPathMap = [self updateSystemToPathMap];
        self.romToSystemMap = [self updateRomToSystemMap];
        self.completionHandler = completionHandler;
    }
    
    return self;
}

- (void)dealloc
{
    self.serialImportQueue = nil;
}

- (void)startImportForPaths:(NSArray *)paths
{
    dispatch_async(self.serialImportQueue, ^{
        NSArray *newPaths = [self importFilesAtPaths:paths];
        [self getRomInfoForFilesAtPaths:newPaths];
        if (self.completionHandler)
        {
            dispatch_sync(dispatch_get_main_queue(), ^{
                self.completionHandler(self.encounteredConflicts);
            });
        }
    });
}

- (NSArray *)importFilesAtPaths:(NSArray *)paths
{
    NSMutableArray *newPaths = [NSMutableArray array];
    for (NSString *path in paths)
    {
        if ([[NSFileManager defaultManager] fileExistsAtPath:[[self romsPath] stringByAppendingPathComponent:path]])
        {
            if ([self isCDROM:path])
            {
                [newPaths addObjectsFromArray:[self moveCDROMToAppropriateSubfolder:path]];
            }
            else
            {
                NSString *newPath = [self moveROMToAppropriateSubfolder:path];
                if ([newPath length])
                {
                    [newPaths addObject:newPath];
                }
            }
        }
    }
    
    return newPaths;
}

- (NSArray *)moveCDROMToAppropriateSubfolder:(NSString *)filePath
{
    NSMutableArray *newPaths = [NSMutableArray array];
    
    NSArray *systemsForExtension = [self systemIDsForRomAtPath:filePath];
    
    NSString *systemID = nil;
    NSString *subfolderPath = nil;
    
    if ([systemsForExtension count] > 1)
    {
        subfolderPath = [self conflictPath];
        self.encounteredConflicts = YES;
    }
    else
    {
        systemID = [systemsForExtension firstObject];
        subfolderPath = self.systemToPathMap[systemID];
    }
    
    if (![subfolderPath length])
    {
        return nil;
    }
    
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:subfolderPath
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error])
    {
        DLog(@"Unable to create %@ - %@", subfolderPath, [error localizedDescription]);
        return nil;
    }
    
    if (![[NSFileManager defaultManager] moveItemAtPath:[[self romsPath] stringByAppendingPathComponent:filePath] toPath:[subfolderPath stringByAppendingPathComponent:filePath] error:&error])
    {
        DLog(@"Unable to move file from %@ to %@ - %@", filePath, subfolderPath, [error localizedDescription]);
        return nil;
    }
    
    if (!self.encounteredConflicts)
    {
        [newPaths addObject:[subfolderPath stringByAppendingPathComponent:filePath]];
    }
    
    // moved the .cue, or .iso or whatever, now move .bins .imgs etc
    
    NSString *relatedFileName = [filePath stringByReplacingOccurrencesOfString:[filePath pathExtension] withString:@""];
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self romsPath] error:&error];
    
    if (!contents)
    {
        DLog(@"Error scanning %@, %@", [self romsPath], [error localizedDescription]);
        return [newPaths copy];
    }
    
    for (NSString *file in contents)
    {
        NSString *fileWithoutExtension = [file stringByReplacingOccurrencesOfString:[file pathExtension] withString:@""];
        
        if ([fileWithoutExtension isEqual:relatedFileName])
        {
            if (![[NSFileManager defaultManager] moveItemAtPath:[[self romsPath] stringByAppendingPathComponent:file] toPath:[subfolderPath stringByAppendingPathComponent:file] error:&error])
            {
                DLog(@"Unable to move file from %@ to %@ - %@", filePath, subfolderPath, [error localizedDescription]);
            }
        }
    }
    
    return [newPaths copy];
}

- (NSString *)moveROMToAppropriateSubfolder:(NSString *)filePath
{
    NSString *newPath = nil;
    
    NSArray *systemsForExtension = [self systemIDsForRomAtPath:filePath];
    
    NSString *systemID = nil;
    NSString *subfolderPath = nil;
    
    if ([systemsForExtension count] > 1)
    {
        subfolderPath = [self conflictPath];
        self.encounteredConflicts = YES;
    }
    else
    {
        systemID = [systemsForExtension firstObject];
        subfolderPath = self.systemToPathMap[systemID];
    }
    
    if (![subfolderPath length])
    {
        return nil;
    }
    
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:subfolderPath
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error])
    {
        DLog(@"Unable to create %@ - %@", subfolderPath, [error localizedDescription]);
        return nil;
    }
    
    if (![[NSFileManager defaultManager] moveItemAtPath:[[self romsPath] stringByAppendingPathComponent:filePath] toPath:[subfolderPath stringByAppendingPathComponent:filePath] error:&error])
    {
        DLog(@"Unable to move file from %@ to %@ - %@", filePath, subfolderPath, [error localizedDescription]);
        return nil;
    }
    
    if (!self.encounteredConflicts)
    {
      newPath = [subfolderPath stringByAppendingPathComponent:filePath];
    }
    
    return newPath;
}

- (NSArray *)conflictedFiles
{
    NSError *error = nil;
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self conflictPath] error:&error];
    if (!contents)
    {
        DLog(@"Unable to get contents of %@ because %@", [self conflictPath], [error localizedDescription]);
    }
    
    return contents;
}

- (void)resolveConflictsWithSolutions:(NSDictionary *)solutions
{
    NSArray *filePaths = [solutions allKeys];
    for (NSString *filePath in filePaths)
    {
        NSString *systemID = solutions[filePath];
        NSString *subfolder = self.systemToPathMap[systemID];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] moveItemAtPath:[[self conflictPath] stringByAppendingPathComponent:filePath] toPath:[subfolder stringByAppendingPathComponent:filePath] error:&error])
        {
            DLog(@"Unable to move %@ to %@ because %@", filePath, subfolder, [error localizedDescription]);
        }
    }
}

#pragma mark - ROM Lookup

- (void)getRomInfoForFilesAtPaths:(NSArray *)paths
{
    RLMRealm *realm = [RLMRealm defaultRealm];
    [realm refresh];
    for (NSString *path in paths)
    {
        @autoreleasepool {
            NSString *systemID = [[PVEmulatorConfiguration sharedInstance] systemIdentifierForFileExtension:[path pathExtension]];
            NSString *partialPath = [systemID stringByAppendingPathComponent:[path lastPathComponent]];
            NSString *title = [[path lastPathComponent] stringByReplacingOccurrencesOfString:[@"." stringByAppendingString:[path pathExtension]] withString:@""];
            PVGame *game = nil;
            RLMResults *results = [PVGame objectsInRealm:realm withPredicate:[NSPredicate predicateWithFormat:@"romPath == %@", partialPath]];
            if ([results count])
            {
                game = [results firstObject];
            }
            else
            {
                if (![systemID length])
                {
                    continue;
                }
                
                game = [[PVGame alloc] init];
                [game setRomPath:partialPath];
                [game setTitle:title];
                [game setSystemIdentifier:systemID];
                [game setRequiresSync:YES];
                [realm beginWriteTransaction];
                [realm addObject:game];
                [realm commitWriteTransaction];
            }
            
            if ([game requiresSync])
            {
                [self lookupInfoForGame:game];
            }
            
            [self getArtworkFromURL:[game originalArtworkURL]];
        }
    }
}

- (void)lookupInfoForGame:(PVGame *)game
{
    RLMRealm *realm = [RLMRealm defaultRealm];
    [realm refresh];
    
    if (![[game md5Hash] length])
    {
         NSString *md5Hash = [[NSFileManager defaultManager] MD5ForFileAtPath:[[self documentsPath] stringByAppendingPathComponent:[game romPath]]];
        
        [realm beginWriteTransaction];
        [game setMd5Hash:md5Hash];
        [realm commitWriteTransaction];
    }
    
    NSError *error = nil;
    NSArray *results = nil;
    
    if ([[game md5Hash] length])
    {
        results = [self searchDatabaseUsingKey:@"romHashMD5"
                                         value:[game md5Hash]
                                      systemID:[game systemIdentifier]
                                         error:&error];
    }
    
    if (![results count])
    {
        NSString *fileName = [[game romPath] lastPathComponent];
        results = [self searchDatabaseUsingKey:@"romFileName"
                                         value:fileName
                                      systemID:[game systemIdentifier]
                                         error:&error];
    }
    
    if (![results count])
    {
        DLog(@"Unable to find ROM (%@) in DB", [game romPath]);
        [realm beginWriteTransaction];
        [game setRequiresSync:NO];
        [realm commitWriteTransaction];
        
        if (self.finishedImportHandler)
        {
            NSString *md5 = [game md5Hash];
            dispatch_sync(dispatch_get_main_queue(), ^{
                self.finishedImportHandler(md5);
            });
        }
        
        return;
    }
    
    NSDictionary *chosenResult = nil;
    for (NSDictionary *result in results)
    {
        if ([result[@"region"] isEqualToString:@"USA"])
        {
            chosenResult = result;
            break;
        }
    }
    
    if (!chosenResult)
    {
        chosenResult = [results firstObject];
    }
    
    [realm beginWriteTransaction];
    [game setRequiresSync:NO];
    [game setTitle:chosenResult[@"gameTitle"]];
    [game setOriginalArtworkURL:chosenResult[@"boxImageURL"]];
    [realm commitWriteTransaction];
    
    if (self.finishedImportHandler)
    {
        NSString *md5 = [game md5Hash];
        dispatch_sync(dispatch_get_main_queue(), ^{
            self.finishedImportHandler(md5);
        });
    }
}

- (void)getArtworkFromURL:(NSString *)url
{
    if (![url length] || [[PVMediaCache filePathForKey:url] length])
    {
        return;
    }
    
    DLog(@"Starting Artwork download for %@", url);
    NSURL *artworkURL = [NSURL URLWithString:url];
    if (!artworkURL)
    {
        return;
    }
    NSURLRequest *request = [NSURLRequest requestWithURL:artworkURL];
    NSHTTPURLResponse *urlResponse = nil;
    NSError *error = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request
                                         returningResponse:&urlResponse
                                                     error:&error];
    if (error)
    {
        DLog(@"error downloading artwork from: %@ -- %@", url, [error localizedDescription]);
        return;
    }
    
    if ([urlResponse statusCode] != 200)
    {
        DLog(@"HTTP Error: %zd", [urlResponse statusCode]);
        DLog(@"Response: %@", urlResponse);
    }
    
    UIImage *artwork = [[UIImage alloc] initWithData:data];
    if (artwork)
    {
        [PVMediaCache writeImageToDisk:artwork withKey:url];
    }
    
    if (self.finishedArtworkHandler)
    {
        dispatch_sync(dispatch_get_main_queue(), ^{
            self.finishedArtworkHandler(url);
        });
    }
}

- (NSArray *)searchDatabaseUsingKey:(NSString *)key value:(NSString *)value systemID:(NSString *)systemID error:(NSError **)error
{
    OESQLiteDatabase *gameDatabase = [[OESQLiteDatabase alloc] initWithURL:[[NSBundle mainBundle] URLForResource:@"openvgdb" withExtension:@"sqlite"]
                                                                     error:error];
    if (!gameDatabase)
    {
        DLog(@"Unable to open game database: %@", [*error localizedDescription]);
        return nil;
    }
    
    NSArray *results = nil;
    NSString *exactQuery = @"SELECT DISTINCT releaseTitleName as 'gameTitle', releaseCoverFront as 'boxImageURL' FROM ROMs rom LEFT JOIN RELEASES release USING (romID) WHERE %@ = '%@'";
    NSString *likeQuery = @"SELECT DISTINCT romFileName as 'romFileName', releaseTitleName as 'gameTitle', releaseCoverFront as 'boxImageURL', regionName as 'region', systemShortName as 'systemShortName' FROM ROMs rom LEFT JOIN RELEASES release USING (romID) LEFT JOIN SYSTEMS system USING (systemID) LEFT JOIN REGIONS region on (regionLocalizedID=region.regionID) WHERE %@ LIKE \"%%%@%%\" AND systemID=\"%@\"";
    NSString *queryString = nil;
    
    NSString *dbSystemID = [[PVEmulatorConfiguration sharedInstance] databaseIDForSystemID:systemID];
    
    if ([key isEqualToString:@"romFileName"])
    {
        queryString = [NSString stringWithFormat:likeQuery, key, value, dbSystemID];
    }
    else
    {
        queryString = [NSString stringWithFormat:exactQuery, key, value];
    }
    
    results = [gameDatabase executeQuery:queryString
                                   error:error];
    return results;
}

#pragma mark - Utils

- (NSString *)documentsPath
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    
    return [paths firstObject];
}

- (NSString *)romsPath
{
    return [[self documentsPath] stringByAppendingPathComponent:@"roms"];
}

- (NSString *)conflictPath
{
    return [[self documentsPath] stringByAppendingPathComponent:@"conflict"];
}

- (NSDictionary *)updateSystemToPathMap
{
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    PVEmulatorConfiguration *emuConfig = [PVEmulatorConfiguration sharedInstance];
    
    for (NSString *systemID in [emuConfig availableSystemIdentifiers])
    {
        NSString *path = [[self documentsPath] stringByAppendingPathComponent:systemID];
        map[systemID] = path;
    }
    
    return [map copy];
}

- (NSDictionary *)updateRomToSystemMap
{
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    PVEmulatorConfiguration *emuConfig = [PVEmulatorConfiguration sharedInstance];
    
    for (NSString *systemID in [emuConfig availableSystemIdentifiers])
    {
        for (NSString *fileExtension in [emuConfig fileExtensionsForSystemIdentifier:systemID])
        {
            NSMutableArray *systems = [map[fileExtension] mutableCopy];
            
            if (!systems)
            {
                systems = [NSMutableArray array];
            }
            
            [systems addObject:systemID];
            map[fileExtension] = [systems copy];
        }
    }
    
    return [map copy];
}

- (NSString *)pathForSystemID:(NSString *)systemID
{
    return self.systemToPathMap[systemID];
}

- (NSArray *)systemIDsForRomAtPath:(NSString *)path
{
    NSString *fileExtension = [[path pathExtension] lowercaseString];
    return self.romToSystemMap[fileExtension];
}

- (BOOL)isCDROM:(NSString *)filePath
{
    BOOL isCDROM = NO;
    
    PVEmulatorConfiguration *emuConfig = [PVEmulatorConfiguration sharedInstance];
    NSArray *cdExtensions = [emuConfig supportedCDFileExtensions];
    NSString *extension = [filePath pathExtension];
    if ([cdExtensions containsObject:extension])
    {
        isCDROM = YES;
    }
    
    return isCDROM;
}

@end