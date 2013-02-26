/*
 * Simple AddressBook query CLI
 * Copyright 2012 Mike Carlton
 *
 * Released under terms of the MIT License: 
 * http://www.opensource.org/licenses/mit-license.php
 *
 * build: 
 * clang -framework Foundation -framework AddressBook -framework AppKit -Wall -o abc abc.m
 * Field names defined in 
 * /System/Library/Frameworks/AddressBook.framework/Versions/A/Headers/ABGlobals.h
 *
 * Structures in
 * /System/Library/Frameworks/AddressBook.framework/Versions/A/Headers/AddressBook.h
 * /System/Library/Frameworks/AddressBook.framework/Versions/A/Headers/ABPerson.h
 * /System/Library/Frameworks/AddressBook.framework/Versions/A/Headers/ABGroup.h
 * /System/Library/Frameworks/AddressBook.framework/Versions/A/Headers/ABAddressBook.h
 *
 * TODO:
 * - sort results according to AB preference (if not specified):
 *      defaultNameOrdering 
 * - additional properties: social media, related dates
 *      kABInstantMessageProperty.
 *      kABOtherDatesProperty, kABMultiDateProperty
 * - handle related names (use record label as display label)
 * - ability to set primary email and address
 * - search dates
 * - search organization as part of name
 * - group search: 
 *      kABGroupNameProperty
 * - display as vcard
 * - escape urls via    (NSString *)
 *      stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding
 * - use person flags (e.g. display as company), see
 *   https://developer.apple.com/library/mac/#samplecode/ABPresence/Listings/ABPersonDisplayNameAdditions_m.html
 */

#import <Foundation/Foundation.h>
#import <AddressBook/AddressBook.h>
#import <Appkit/NSWorkspace.h>

#include <getopt.h>

#define numElts(array) (sizeof(array)/sizeof(*array))
#define max(a, b) ((a) > (b) ? (a) : (b))
#define min(a, b) ((a) < (b) ? (a) : (b))
#define plural(n) ((n) == 1 ? "" : "s")
#define eplural(n) ((n) == 1 ? "" : "es")

typedef enum {
    labelNone,
    labelHome,
    labelWork,
} Preferred;

typedef enum
{
    standardDisplay,
    briefDisplay,
    longDisplay,
    rawDisplay,
} DisplayForm;

typedef enum
{
    searchNames,
    searchGroups,
    searchAll,
} SearchFields;

Boolean urlGui = false;     // open browser gui with URL?
Boolean emailGui = false;   // open gui email?
Boolean mapGui = false;     // open gui map?
Boolean abGui = false;      // open gui address book?
Boolean edit = false;       // gui address book in edit mode?

int listGroups = false;     // list all groups?
Boolean uid = false;        // display/search records with uid?
const char *uidStr = NULL;  // uid to search for 

Preferred label = labelNone;                // use which label?
DisplayForm displayForm = standardDisplay;  // default type of display
SearchFields searchFields = searchAll;      // default type of search

typedef struct
{
    const char *label;
    NSString *property;
    int abType;
    int labelWidth;
    // int valueWidth;
    union 
    {
        id generic;
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
    finalname = maidenname,     // mark final name
    organization,
    address,
    phone,
    email,
    jobtitle,
    url,
    birthday,
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
 * nsprintf utility (allows printf-like with NSString support)
 */
void
nsprintf(NSString *format, ...) 
{
    va_list args;
    va_start(args, format);
    NSString *formattedStr = [[NSString alloc] initWithFormat: format
                                                  arguments: args];
    va_end(args);

    NSFileHandle *output = [NSFileHandle fileHandleWithStandardOutput];
    [output writeData: [formattedStr dataUsingEncoding: NSNEXTSTEPStringEncoding]];
//    [[NSFileHandle fileHandleWithStandardOutput]
//        writeData: [formattedStr dataUsingEncoding: NSNEXTSTEPStringEncoding]];
    [formattedStr release];
}

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
        { "Organization", kABOrganizationProperty, kABStringProperty },
        { "Address",      kABAddressProperty,      kABMultiDictionaryProperty },
        { "Phone",        kABPhoneProperty,        kABMultiStringProperty },
        { "Email",        kABEmailProperty,        kABMultiStringProperty },
        { "Job Title",    kABJobTitleProperty,     kABStringProperty },
        { "URL",          kABURLsProperty,         kABMultiStringProperty },
        { "Birthday",     kABBirthdayProperty,     kABDateProperty },
        { "Related",      kABRelatedNamesProperty, kABMultiStringProperty },
        { "Note",         kABNoteProperty,         kABStringProperty },
    };

    for (int i=0; i<numElts(fieldInit); i++, field++)
    {
        *field = fieldInit[i];
        field->labelWidth = strlen(field->label);
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

const char *
str(NSString *ns)
{
    const char *s = NULL;

    if (ns)
    {
        s = [ns UTF8String];
    }

    return (s) ? s : "";
}

/* 
 * Allocate and return a cleaned up label
 * Standard (Apple defined) labels come out of AB like this: _$!<Work>!$_
 * User-defined labels are unadorned, e.g. Account
 */
const char *cleanLabel(const char *label)
{
    const char *kind;

    const char *start = index(label, '<');
    const char *end = rindex(label, '>');
    if (start && end && end > start)
    {
        kind = strndup(start+1, end-start-1);
    } else {
        kind = strdup(label);
    }

    return kind;
}

/*
 * returns first value with matching label
 */
id
getValueWithLabel(ABMultiValue *multi, NSString *labelWanted)
{
    id result = nil;
    unsigned int count = [multi count];

    for (unsigned int i = 0; i < count; i++) 
    {
        if ([labelWanted isEqualToString:[multi labelAtIndex:i]] == true)
        {
            result = [multi valueAtIndex:i];
            break;
        }
    }

    return result;
}

/*
 * Format and return a formatted address
 * FIXME: use formattedAddressFromDictionary
 */
char *
formattedAddress(NSDictionary *value, bool url)
{
    static char buffer[1024];

    snprintf(buffer, sizeof(buffer), "%s, %s %s %s", 
            str([value objectForKey: kABAddressStreetKey]),
            str([value objectForKey: kABAddressCityKey]),
            str([value objectForKey: kABAddressStateKey]),
            str([value objectForKey: kABAddressZIPKey]));

    if (url) /* escape any spaces */
    {
        char *s = buffer;
        while ((s = index(s, ' ')))
        {
            *s='+';
        }
    }

    return buffer;
}

/*
 * returns identifier for preferred label of property
 *
 * if preferred is none, return first match of primary, home, work
 * else return first match of home or work as requested
 */
id
getPreferredProperty(ABPerson *person, NSString *property, Preferred label)
{
    ABMultiValue *multi = [person valueForProperty:property];
    NSString *identifier = nil;
    id value = nil;

    switch (label)
    {
        case labelNone:
            identifier = [multi primaryIdentifier]; 
            if (identifier)
            {
                value = [multi valueForIdentifier:identifier];
                break;
            } // else fall through to home next
        case labelHome:
            value = getValueWithLabel(multi, kABHomeLabel);

            // try "HomePage" also if property is URLs
            if (!value && [property isEqualToString:kABURLsProperty])
            {
                value = getValueWithLabel(multi, kABHomePageLabel );
            }
            if (value)
            {
                break;
            } // else fall through to work
        case labelWork:
            value = getValueWithLabel(multi, kABWorkLabel);
            break;
        default:
            break;
    }

    return value;
}

/* 
 * Open the specified URL
 */
void 
openURL(NSString *url)
{
    // stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
}

/* 
 * Open up a browser with the person's URL
 */
void openInBrowser(ABPerson *person, Preferred label)
{
    NSString *url = getPreferredProperty(person, kABURLsProperty, label);

    if (url)
    {
        openURL(url);
    }
}

/* 
 * Open up a browser with the person's address mapped
 */
void openInMapping(ABPerson *person, Preferred label)
{
    NSDictionary *address = getPreferredProperty(person, kABAddressProperty, 
                                                 label);

    if (address)
    {
        NSString *url = [NSString stringWithFormat:
                            @"http://maps.google.com/maps?q=%s", 
                            formattedAddress(address, true)];
        openURL(url);
    }
}

/* 
 * Open up the email application with a new message for person
 */
void openInEmail(ABPerson *person, Preferred label)
{
    NSString *email = getPreferredProperty(person, kABEmailProperty, label);

    if (email)
    {
        NSString *url = [NSString stringWithFormat:@"mailto:%@", email];

        openURL(url);
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
    NSString *url = [NSString stringWithFormat:@"addressbook://%@%s", 
                            [person uniqueId], edit ? "?edit" : ""];
    
    openURL(url);
}

/*
 * Print a multi-line value, label for first line is already printed
 */
void printNote(int labelWidth, const char *note)
{
    Boolean first = true;
    int length, offset;

    const char *end = note + strlen(note);
    while (note < end)
    {
        if (!first)
        {
            printf("%*s: ", labelWidth, "");
        }
        
        length = strlen(note);
        offset = strcspn(note, "\r\n");

        printf("%.*s\n", offset, note);
        note += offset;
        note++;
        first = false;
    }
}

// convenience method to extract proper C string from NSDictionary
const char *keyFrom(id value, NSString *key)
{
    return str([value objectForKey: key]);
}

void
printField(Field *field, const char *label, int width, char *terminator, 
           bool abbrev)
{
    unsigned int count;

    if (label)
    {
        printf("%*s: ", width, label);  // if requested, label on 1st line only
    }

    switch (field->abType)
    {
        case kABStringProperty:
            if (field->property == kABNoteProperty)  // multi-line string
            {                                   
                printNote(width, str(field->value.string));
            } else {                                   // simple string
                printf("%s%s", str(field->value.string), terminator);
            }
            break;
        case kABDateProperty:
            printf("%s%s", str([field->value.date 
                         descriptionWithCalendarFormat: @"%A, %B %e, %Y"
                         timeZone: nil locale: nil]), terminator);
            break;
        case kABMultiStringProperty:
            count = [field->value.multi count];
            for (unsigned int j = 0; j < count; j++) 
            {
                const char *value = str([field->value.multi valueAtIndex:j]);
                const char *kind = str([field->value.multi labelAtIndex:j]);

                kind = cleanLabel(kind);  // returns a duplicate, must free
                if (label && j > 0)       // multiple values
                {
                    printf("%*s: ", width, "");
                }
                printf("%s (%.*s)%s", value, abbrev ? 1 : -1, kind, terminator);
                free((void *)kind);
            }
            break;
        case kABMultiDictionaryProperty:
            count = [field->value.multi count];
            for (unsigned int j = 0; j < count; j++) 
            {
                NSDictionary *value = [field->value.multi valueAtIndex:j];
                const char *kind = str([field->value.multi labelAtIndex:j]);

                kind = cleanLabel(kind);  // returns a duplicate
                if (label && j > 0)       // multiple values
                {
                    printf("%*s: ", width, "");
                }
                printf("%s, %s %s %s (%.*s)%s", 
                        str([value objectForKey: kABAddressStreetKey]),
                        str([value objectForKey: kABAddressCityKey]),
                        str([value objectForKey: kABAddressStateKey]),
                        str([value objectForKey: kABAddressZIPKey]),
                        abbrev ? 1 : -1, kind, terminator);
                free((void *)kind);
            }
            break;
        default:
            break;
    }
}

/*
 * Allocate and print a formatted name
 * Uses nickname (if present) instead of first name
 * Uses organization (if present) if none of nickname, first and last are present
 */
void
printFormattedName(char *terminator)
{
    int first = firstname;

    if (field[nickname].value.generic)
    {
        first = nickname;
    }
    if (field[first].value.generic || field[lastname].value.generic)
    {
        printField(&field[first], NULL, 0, " ", true);
        printField(&field[lastname], NULL, 0, terminator, true);
    } else if (field[organization].value.generic)
    {
        printField(&field[organization], NULL, 0, terminator, true);
    }
}

/*
 * Display person in brief format
 */
void
displayBrief(void)
{
    NSString *phoneLabels[] =
    {
        kABPhoneMobileLabel,
        kABPhoneHomeLabel,
        kABPhoneWorkLabel
    };

    NSString *emailLabels[] =
    {
        kABEmailHomeLabel,
        kABEmailWorkLabel
    };

    printFormattedName(" ");
    
    // first of each phone type
    for (int i=0; i<numElts(phoneLabels); i++)
    {
        NSString *s = getValueWithLabel(field[phone].value.multi, 
                                        phoneLabels[i]);
        if (s)
        {
            const char *kind = cleanLabel(str(phoneLabels[i]));

            printf("%s (%.1s) ", str(s), kind);
        }
    }

    // first of each email type
    for (int i=0; i<numElts(emailLabels); i++)
    {
        NSString *s = getValueWithLabel(field[email].value.multi, 
                                        emailLabels[i]);
        if (s)
        {
            const char *kind = cleanLabel(str(emailLabels[i]));

            printf("%s (%.1s) ", str(s), kind);
        }
    }

    printf("\n");
}

void 
displayRaw(ABRecord *record)
{
    printf("%s\n", str([record description]));
}


/*
 * Display one group record
 */
void 
displayGroup(ABGroup *group, DisplayForm form)
{
    if (form == rawDisplay)
    {
        displayRaw(group);
        return;
    }

    NSString *name = [group valueForProperty:kABGroupNameProperty];
    printf("%s", str(name));

    if (form == briefDisplay)
    {
        printf("\n");
        return;
    }

    NSArray *members = [group members];
    int length = [members count];
    printf(" (%d member%s)\n", length, plural(length));

    if (form == longDisplay)
    {
        NSEnumerator *membersEnum = [members objectEnumerator];
        ABPerson *person;
        while (person = (ABPerson *)[membersEnum nextObject]) 
        {
            for (unsigned int i=0; i<finalname; i++)
            {
                field[i].value.string = [person 
                        valueForProperty:field[i].property];
            }
            printf("\t");
            printFormattedName("\n");
        }

        return;
    }
}

/*
 * Display one person record
 */
void 
display(ABPerson *person, DisplayForm form)
{
    if (form == rawDisplay)
    {
        displayRaw(person);
        return;
    }

    /* retrieve all values and find widest label of non-null values */
    int labelWidth = 0;
    for (unsigned int i=0; i<numFields; i++)
    {
        if (form == standardDisplay && i > email)   // stop here for standard
        {
            break;
        }

        field[i].value.generic = [person valueForProperty:field[i].property];

        int width = (form == standardDisplay && i <= finalname ) ? 
                        strlen("Name") : field[i].labelWidth;
        if (field[i].value.generic && width > labelWidth)
        {
            labelWidth = width;
        }
    }

    /* if brief requested, print it and return */
    if (form == briefDisplay)
    {
        displayBrief();
        return;
    }

    /* print non-null fields */
    for (unsigned int i=0; i<numFields; i++)
    {
        if (!field[i].value.generic)                 // skip if empty
        {
            continue;
        }

        if (form == standardDisplay && i > email)   // stop here for standard
        {
            break;
        }

        if (form == standardDisplay && i <= finalname)  // print formatted name
        {
            printf("%*s: ", labelWidth, "Name");
            printFormattedName("\n");
            i = finalname;                          // skip other name fields
        }
        else
        {
            printField(&field[i], field[i].label, labelWidth, "\n", false);
        }
    }

    if (uid)
    {
        const char *uidStr = str([person valueForProperty:kABUIDProperty]);
        printf("%*s: %.*s\n", labelWidth, "UID", 
               (int)(rindex(uidStr, ':') - uidStr), uidStr);
    }

    printf("\n");
}

NSArray *search(ABAddressBook *book, int numTerms, char * const term[])
{
    NSMutableArray *searchTerms = [NSMutableArray new];

    // FIXME: add search for group
    int fieldLimit = (searchFields == searchNames) ? finalname : numFields;

    for (int i=0; i<numTerms; i++)
    {
        NSString *key = [NSString stringWithCString:term[i] 
                                    encoding: NSUTF8StringEncoding];
        NSMutableArray *searchRecord = [NSMutableArray new];

        /* look for term in name or all fields */
        for (unsigned int j=0; j<fieldLimit; j++)
        {
#if 1
            [searchRecord addObject: 
                [ABPerson searchElementForProperty:field[j].property
                    label:nil       /* use this to filter Home v. Work */
                    //label:kABAddressHomeLabel
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

    /* if a UID is given, require it to match also */
    if (uidStr)
    {
        [searchTerms addObject: 
            [ABPerson searchElementForProperty:kABUIDProperty
                            label:nil       
                            key:nil
                            value: [NSString stringWithCString:uidStr
                                             encoding: NSUTF8StringEncoding]
                            comparison:kABContainsSubStringCaseInsensitive]];
    }

    /* search all records for each term */
    ABSearchElement *search = [ABSearchElement 
                                searchElementForConjunction:kABSearchAnd
                                children:searchTerms];

    return [book recordsMatchingSearchElement:search];
}

/*
 * Returns a new array sorted by keys
 */
NSArray *
sortBy(NSArray *unsorted, unsigned int numKeys, NSString *keys[])
{
    NSMutableArray *descriptors = [NSMutableArray new];
    
    for (unsigned int i=0; i<numKeys; i++)
    {
        [descriptors addObject: [[NSSortDescriptor alloc]
                                    initWithKey:keys[i]
                                    ascending:YES
                        selector:@selector(localizedCaseInsensitiveCompare:)]];
    }

    return [unsorted sortedArrayUsingDescriptors:descriptors];
}

/*
    search filters:
        first F 
        first L 
        notes N
        email M
        city C
        street S
    limit n <arg>
    interactive i
 */

/*
 * Summarize program usage 
 */
static const char *options = ":sblrnaghuAEMUHW";
static struct option longopts[] = 
{
     { "std",     no_argument,       NULL,           's' },
     { "brief",   no_argument,       NULL,           'b' },
     { "long",    no_argument,       NULL,           'l' },
     { "raw",     no_argument,       NULL,           'r' },

     { "name",    no_argument,       NULL,           'n' },
     { "all",     no_argument,       NULL,           'a' },
     // FIXME { "group",   no_argument,       NULL,           'g' },

     { "help",    no_argument,       NULL,           'h' },
     { "uid",     optional_argument, NULL,           'u' },

     { "groups",  no_argument,       &listGroups,     1 },

     { "address", no_argument,       NULL,           'A' },
     { "email",   no_argument,       NULL,           'E' },
     { "map",     no_argument,       NULL,           'M' },
     { "url",     no_argument,       NULL,           'U' },
     { "home",    no_argument,       NULL,           'H' },
     { "work",    no_argument,       NULL,           'W' },

     { NULL,      0,                 NULL,           0 }
};

static void 
usage(char *name)
{
    int i;
    static char *help[] = {
      "  -s, --std      display records in standard form (default)",
      "  -b, --brief    display records in brief form",
      "  -l, --long     display records in long form",
      "  -r, --raw      display records in raw form",
      "",
      "  -a, --all      search all Person fields (default)",
      "  -n, --name     search name fields only",
      // FIXME "  -g, --group    search group name only",
      "",
      "  -h, --help     this help",
      "  -u, --uid[=id] display unique ids; search for id if given",
      "",
      "      --groups   list all groups",
      "",
      "  -A, --address  open Address Book with person",
      "  -E, --email    open email application with message for person",
      "  -M, --map      open map application with address of person",
      "  -U, --url      open browser with URL of person",
      "  -H, --home     use 'home' values for gui",
      "  -W, --work     use 'work' values for gui",
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
        while ((opt = getopt_long(argc, argv, options, longopts, NULL)) >= 0) 
        {
            if (opt == 0)
            {
                continue;       // long opt only
            }

            switch (opt) 
            {
                case 's': displayForm = standardDisplay; break;
                case 'b': displayForm = briefDisplay;    break;
                case 'l': displayForm = longDisplay;     break;
                case 'r': displayForm = rawDisplay;      break;

                case 'n': searchFields = searchNames; break;
                case 'g': searchFields = searchGroups; break;
                case 'a': searchFields = searchAll;   break;

                case 'A': abGui = true; edit = false; break;
                case 'E': emailGui = true;            break;
                case 'M': mapGui = true;              break;
                case 'U': urlGui = true;              break;

                case 'H': label = labelHome; break;
                case 'W': label = labelWork; break;

                case 'u': uid = true; uidStr = optarg; break;

                case 'h':
                default:
                    usage(programName);
                    break;
            }
        }

        argc -= optind;
        argv += optind;

        if (argc < 1 && !uidStr && !listGroups)
        {
            usage(programName);
        }

        // properties (e.g. kABFirstNameProperty) are not compile-time constants
        init(field, addressKey);

        ABAddressBook *book = [ABAddressBook sharedAddressBook];
        
        if (listGroups)
        {
            NSString *keys[] = { @"GroupName" };
            NSArray *groups = sortBy([book groups], numElts(keys), keys);
            NSEnumerator *groupEnum = [groups objectEnumerator];

            ABGroup *group;
            while (group = (ABGroup *)[groupEnum nextObject]) 
            {
                displayGroup(group, displayForm);
            }

            return 0;
        }

        NSArray *results = search(book, argc, argv);
        NSString *keys[] = { @"Last", @"First", @"Organization" };
        NSArray *sortedResults = sortBy(results, numElts(keys), keys);

        NSEnumerator *addressEnum = [sortedResults objectEnumerator];

        ABPerson *person;
        while (person = (ABPerson *)[addressEnum nextObject]) 
        {
            display(person, displayForm);
            if (abGui)
            {
                openInAddressBook(person, edit);
                break;
            }
            if (urlGui)
            {
                openInBrowser(person, label);
                break;
            }
            if (mapGui)
            {
                openInMapping(person, label);
                break;
            }
            if (emailGui)
            {
                openInEmail(person, label);
                break;
            }
        }

        unsigned long numResults = [results count];
        if (numResults != 1)
        {
            printf("%lu match%s\n", numResults, eplural(numResults));
        }
    }

    return 0;
}

/* vim: set ts=4 sw=4 sts=4 et: */
