/*
 * Simple AddressBook query CLI
 * Copyright 2012 Mike Carlton
 *
 * Released under terms of the MIT License: 
 * http://www.opensource.org/licenses/mit-license.php
 *
 * build: 
 * clang -framework Foundation -framework AddressBook -framework AppKit \
 *       -Wall -o abq abq.m
 */

#import <Foundation/Foundation.h>
#import <AddressBook/AddressBook.h>
#import <Appkit/NSWorkspace.h>

#include <getopt.h>

#define numElts(array) (sizeof(array)/sizeof(*array))
#define max(a, b) ((a) > (b) ? (a) : (b))
#define min(a, b) ((a) < (b) ? (a) : (b))

Boolean gui = false;
Boolean edit = false;
Boolean raw = false;

/* 
 * Field names defined in 
 * /System/Library/Frameworks/AddressBook.framework/Versions/A/Headers/ABGlobals.h
 *
 * Structures in
 * /System/Library/Frameworks/AddressBook.framework/Versions/A/Headers/AddressBook.h
 * /System/Library/Frameworks/AddressBook.framework/Versions/A/Headers/ABAddressBook.h
*/

typedef struct
{
    const char *label;
    NSString *property;
    int abType;
    union 
    {
        NSString *string;
        ABMultiValue *multi;
        NSDate *date;
    } value;
} Field;

enum 
{
    firstname,
    middlename,
    lastname,
    nickname,
    maidenname,
    birthday,
    organization,
    jobtitle,
    phone,
    email,
    address,
    url,
    related,
    note,
    numFields,
};

Field field[numFields];

enum
{
    addressStreet,
    addressCity,
    addressState,
    addressZIP,
    addressCountry,
    addressCountryCode,
    numAddressKeys,
};

NSString *addressKey[numAddressKeys];

/*
 * Initialize the fields
 */
void init(Field *field, NSString **addressKey)
{
    Field fieldInit[] = 
    {
        { "First Name",   kABFirstNameProperty,    kABStringProperty },
        { "Middle Name",  kABMiddleNameProperty,   kABStringProperty },
        { "Last Name",    kABLastNameProperty,     kABStringProperty },
        { "Nickname",     kABNicknameProperty,     kABStringProperty },
        { "Maiden Name",  kABMaidenNameProperty,   kABStringProperty },
        { "Birthday",     kABBirthdayProperty,     kABDateProperty },
        { "Organization", kABOrganizationProperty, kABStringProperty },
        { "Job Title",    kABJobTitleProperty,     kABStringProperty },
        { "Phone",        kABPhoneProperty,        kABMultiStringProperty },
        { "Email",        kABEmailProperty,        kABMultiStringProperty },
        { "Address",      kABAddressProperty,      kABMultiDictionaryProperty },
        { "URL",          kABURLsProperty,         kABMultiStringProperty },
        { "Related",      kABRelatedNamesProperty, kABMultiStringProperty },
        { "Note",         kABNoteProperty,         kABStringProperty },
    };

    for (int i=0; i<numElts(fieldInit); i++, field++)
    {
        *field = fieldInit[i];
    }

    NSString *addressInit[] =
    {
        kABAddressStreetKey,
        kABAddressCityKey,
        kABAddressStateKey,
        kABAddressZIPKey,
        kABAddressCountryKey,
        kABAddressCountryCodeKey,
    };

    for (int i=0; i<numElts(addressInit); i++, addressKey++)
    {
        *addressKey = addressInit[i];
    }
}

/* 
 * Open up the Address Book application with the person displayed
 * and optionally in edit mode
 * Reference: 
 * /System/Library/Frameworks/AddressBook.framework/Versions/A/Headers/ABAddressBook.h
 */
void openInAddressBook(ABPerson *person, Boolean edit)
{
    NSString *urlString = [NSString stringWithFormat:@"addressbook://%@%s", 
                            [person uniqueId], edit ? "?edit" : ""];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:urlString]];
}

const char *str(NSString *ns)
{
    const char *s;

    if (ns)
    {
        s = [ns UTF8String];
    }

    return (s) ? s : "";
}

// convenience method to extract proper C string from NSDictionary
const char *keyFrom(id value, NSString *key)
{
    return str([value objectForKey: key]);
}

/*
 * Display one record
 */
void display(ABPerson *person)
{
    if (raw)
    {
        printf("%s\n", str([person description]));
        return;
    }

    for (unsigned int i=0; i<numFields; i++)
    {
        id value = [person valueForProperty:field[i].property];
        if (value)
        {
            switch (field[i].abType)
            {
                case kABStringProperty:
                    field[i].value.string = value;
                    printf("%s: %s\n", 
                            field[i].label, str(field[i].value.string));
                    break;
                case kABDateProperty:
                    field[i].value.date = value;
                    printf("%s: %s\n", 
                            field[i].label, 
                            str([field[i].value.date 
                                 descriptionWithCalendarFormat: @"%A, %B %e, %Y"
                                 timeZone: nil locale: nil]));
                    break;
                case kABMultiStringProperty:
                    field[i].value.multi = value;
                    unsigned int count = [field[i].value.multi count];
                    for (unsigned int j = 0; j < count; j++) 
                    {
                        const char *value = str([field[i].value.multi 
                                                    valueAtIndex:j]);
                        const char *label = str([field[i].value.multi 
                                                    labelAtIndex:j]);

                        const char *kind;
                        /* labels come out of AB like this: _$!<Work>!$_ */
                        char *start = index(label, '<');
                        char *end = rindex(label, '>');
                        if (start && end && end > start)
                        {
                            kind = strndup(start+1, end-start-1);
                        } else {
                            kind = label;
                        }
                        printf("%s: %s (%s)\n", field[i].label, value, kind);
                        if (kind != label)
                        {
                            free((void *)kind);
                        }
                    }
                    break;
                case kABMultiDictionaryProperty:
                    field[i].value.multi = value;
                    count = [field[i].value.multi count];
                    for (unsigned int j = 0; j < count; j++) 
                    {
                        NSDictionary *value = [field[i].value.multi 
                                                    valueAtIndex:j];
                        const char *label = str([field[i].value.multi 
                                                    labelAtIndex:j]);

                        const char *kind;
                        /* labels come out of AB like this: _$!<Work>!$_ */
                        const char *start = index(label, '<');
                        const char *end = rindex(label, '>');
                        if (start && end && end > start)
                        {
                            kind = strndup(start+1, end-start-1);
                        } else {
                            kind = label;
                        }
                        printf("%s: %s, %s %s %s (%s)\n", field[i].label, 
                                str([value objectForKey: kABAddressStreetKey]),
                                str([value objectForKey: kABAddressCityKey]),
                                str([value objectForKey: kABAddressStateKey]),
                                str([value objectForKey: kABAddressZIPKey]),
                                kind);
                        if (kind != label)
                        {
                            free((void *)kind);
                        }
                    }
                    break;
                default:
                    break;
            }
        }
    }
    printf("\n");
}

NSArray *search(ABAddressBook *book, int numTerms, char * const term[])
{
    NSMutableArray *searchTerms = [NSMutableArray new];

    for (int i=0; i<numTerms; i++)
    {
        NSString *key = [NSString stringWithCString:term[i] 
                                    encoding: NSUTF8StringEncoding];
        NSMutableArray *searchRecord = [NSMutableArray new];

        /* look for term in any fields */
        for (unsigned int j=0; j<numFields; j++)
        {
#if 1
            [searchRecord addObject: 
                [ABPerson searchElementForProperty:field[j].property
                    label:nil       /* use this to filter Home v. Work */
                    key:nil
                    value:key
                    comparison:kABContainsSubStringCaseInsensitive]];
#else
            switch (field[j].abType)
            {
                case kABStringProperty:
                case kABMultiStringProperty:    /* may differ for filtering */
                    [searchRecord addObject: 
                        [ABPerson searchElementForProperty:field[j].property
                            label:nil       /* use this to filter Home v. Work */
                            key:nil
                            value:key
                            comparison:kABContainsSubStringCaseInsensitive]];
                    break;
                case kABDateProperty:
                    break;
                case kABMultiDictionaryProperty:
                    // FIXME: assume MultiDictionary is Address (currently true)
                    // search on indiviual keys
                    break;
            }
#endif
        }

        [searchTerms addObject: [ABSearchElement 
                                    searchElementForConjunction:kABSearchOr
                                    children:searchRecord]];
    }

    /* search all records for each term */
    ABSearchElement *search = [ABSearchElement 
                                searchElementForConjunction:kABSearchAnd
                                children:searchTerms];

    return [book recordsMatchingSearchElement:search];
}

/*
    open O
    edit E
    display filters:
        home H
        work W
    search filters:
        first F 
        first L 
        notes N
        email M
        city C
        street S
    raw r [description]
    display type:
        short
        normal
        long
    limit n <arg>
 */

/*
 * Summarize program usage 
 */
static void 
usage(char *name)
{
    int i;
    static char *help[] = {
      "  -h           this help",
      "  -O           open Address Book, showing first match",
      "  -E           open Address Book, editing first match",
      "  -r           display records in raw form",
    };

    fprintf(stderr, "usage: %s [options] search term(s)\n", name);
    for (i=0; i<numElts(help); i++) 
    {
        fprintf(stderr, "%s\n", help[i]);
    }

    exit(0);
}

int main(int argc, char * const argv[])
{
    @autoreleasepool 
    {
        char *programName = argv[0];

        int opt;
        while ((opt = getopt(argc, argv, ":hOEr")) > 0) 
        {
            switch (opt) 
            {
                case 'O':
                    // nw.name = optarg;
                    gui = true;
                    edit = false;
                    break;
                case 'E':
                    gui = true;
                    edit = true;
                    break;
                case 'r':
                    raw = true;
                    break;
                case 'h':
                default:
                    usage(programName);
                    break;
            }
        }

        argc -= optind;
        argv += optind;

        if (argc < 1)
        {
            usage(programName);
        }

        // properties (e.g. kABFirstNameProperty) are not compile-time constants
        init(field, addressKey);

        ABAddressBook *book = [ABAddressBook sharedAddressBook];
        
        NSArray *results = search(book, argc, argv);

        NSEnumerator *addressEnum = [results objectEnumerator];

        ABPerson *person;
        while (person = (ABPerson *)[addressEnum nextObject]) 
        {
            display(person);
            if (gui)
            {
                openInAddressBook(person, edit);
                break;
            }
        }
    }

    return 0;
}

/* vim: set ts=4 sw=4 sts=4 et: */
