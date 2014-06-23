/*
 * Simple Contacts (AddressBook) query CLI
 * Copyright 2012-2014 Mike Carlton
 *
 * Released under terms of the MIT License:
 * http://www.opensource.org/licenses/mit-license.php
 *
 * build:
   clang -framework Foundation -framework AddressBook -framework AppKit \
     -Wall -Werror -Weverything -Wno-format-nonliteral -Wno-missing-field-initializers -Wno-shadow \
     -o abc abc.m
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
#define plural(n) ((n) == 1 ? "" : "s")
#define eplural(n) ((n) == 1 ? "" : "es")

typedef enum {
    labelNone,
    labelHome,
    labelWork,
} Preferred;

typedef enum
{
    plainDisplay,
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

static Boolean urlGui = false;        // open browser gui with URL?
static Boolean emailGui = false;      // open gui email?
static Boolean googleMapsGui = false; // open gui google maps?
static Boolean mapsGui = false;       // open gui maps?
static Boolean contactsGui = false;   // open gui address book?
static Boolean edit = false;          // gui address book in edit mode?

static int listGroups = false;     // list all groups?
static Boolean uid = false;        // display/search records with uid?
static const char *uidStr = NULL;  // uid to search for

static Preferred label = labelNone;                // use which label?
static DisplayForm displayForm = standardDisplay;  // default type of display
static SearchFields searchFields = searchAll;      // default type of search

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
    social,
    note,
    numFields,
};

static Field field[numFields];

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

static NSString *addressKey[numAddressKeys];

/*
 * Initialize the fields
 */
static void
init(Field *field, NSString **addressKey)
{
    Field fieldInit[] =
    {
        { "First Name",   kABFirstNameProperty,     kABStringProperty },
        { "Middle Name",  kABMiddleNameProperty,    kABStringProperty },
        { "Last Name",    kABLastNameProperty,      kABStringProperty },
        { "Nickname",     kABNicknameProperty,      kABStringProperty },
        { "Maiden Name",  kABMaidenNameProperty,    kABStringProperty },
        { "Organization", kABOrganizationProperty,  kABStringProperty },
        { "Address",      kABAddressProperty,       kABMultiDictionaryProperty },
        { "Phone",        kABPhoneProperty,         kABMultiStringProperty },
        { "Email",        kABEmailProperty,         kABMultiStringProperty },
        { "Job Title",    kABJobTitleProperty,      kABStringProperty },
        { "URL",          kABURLsProperty,          kABMultiStringProperty },
        { "Birthday",     kABBirthdayProperty,      kABDateProperty },
        { "Related",      kABRelatedNamesProperty,  kABMultiStringProperty },
        { "Social",       kABSocialProfileProperty, kABMultiDictionaryProperty },
        { "Note",         kABNoteProperty,          kABStringProperty },
    };

    for (unsigned int i=0; i<numElts(fieldInit); i++, field++)
    {
        *field = fieldInit[i];
        field->labelWidth = (int)strlen(field->label);
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

    for (unsigned int i=0; i<numElts(addressInit); i++, addressKey++)
    {
        *addressKey = addressInit[i];
    }
}

static const char *
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
static const char *
cleanLabel(const char *label)
{
    const char *kind;

    const char *start = index(label, '<');
    const char *end = rindex(label, '>');
    if (start && end && end > start)
    {
        kind = strndup(start+1, (size_t)(end-start-1));
    } else {
        kind = strdup(label);
    }

    return kind;
}

/*
 * returns first value with matching label
 */
static id
getValueWithLabel(ABMultiValue *multi, NSString *labelWanted)
{
    id result = nil;
    unsigned long count = [multi count];

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
static char *
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
static id
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
    }

    return value;
}

/*
 * Open the specified URL
 */
static void
openURL(NSString *url)
{
    // stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
}

/*
 * Open up a browser with the person's URL
 */
static void
openInBrowser(ABPerson *person, Preferred label)
{
    NSString *url = getPreferredProperty(person, kABURLsProperty, label);

    if (url)
    {
        openURL(url);
    }
}

/*
 * Open given mapping url
 */
static void
openInMappingProvider(ABPerson *person, Preferred label, const char *provider)
{
    NSDictionary *address = getPreferredProperty(person, kABAddressProperty,
                                                 label);

    if (address)
    {
        NSString *url = [NSString stringWithFormat:
                            @"http://maps.%s.com/maps?q=%s",
                            provider,
                            formattedAddress(address, true)];
        openURL(url);
    }
}

/*
 * Open up a browser with the person's address in Google Maps
 */
static void
openInGoogleMapping(ABPerson *person, Preferred label)
{
    openInMappingProvider(person, label, "google");
}

/*
 * Open Maps application with the person's address mapped
 */
static void
openInMapping(ABPerson *person, Preferred label)
{
    openInMappingProvider(person, label, "apple");
}

/*
 * Open up the email application with a new message for person
 */
static void
openInEmail(ABPerson *person, Preferred label)
{
    NSString *email = getPreferredProperty(person, kABEmailProperty, label);

    if (email)
    {
        NSString *url = [NSString stringWithFormat:@"mailto:%@", email];

        openURL(url);
    }
}

/*
 * Open up the Contacts application with the person displayed
 * and optionally in edit mode
 * Reference:
 * /System/Library/Frameworks/AddressBook.framework/Versions/A/Headers/ABAddressBook.h
 */
static void
openInContacts(ABPerson *person, Boolean edit)
{
    NSString *url = [NSString stringWithFormat:@"addressbook://%@%s",
                            [person uniqueId], edit ? "?edit" : ""];

    openURL(url);
}

/*
 * Print a multi-line value, label for first line is already printed
 */
static void
printNote(int labelWidth, const char *note)
{
    Boolean first = true;
    size_t length, offset;

    const char *end = note + strlen(note);
    while (note < end)
    {
        if (!first)
        {
            printf("%*s: ", labelWidth, "");
        }

        length = strlen(note);
        offset = strcspn(note, "\r\n");

        printf("%.*s\n", (int)offset, note);
        note += offset;
        note++;
        first = false;
    }
}

static void
printField(Field *field, const char *label, int width, char *terminator,
           bool abbrev)
{
    unsigned long count;

    switch (field->abType)
    {
        case kABStringProperty:
            if (label)              // if requested, label on 1st line only
            {
                printf("%*s: ", width, label);
            }

            if (field->property == kABNoteProperty)  // multi-line string
            {
                printNote(width, str(field->value.string));
            } else {                                   // simple string
                printf("%s%s", str(field->value.string), terminator);
            }
            break;
        case kABDateProperty:
            if (label)              // if requested, label on 1st line only
            {
                printf("%*s: ", width, label);
            }
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

                kind = cleanLabel(kind);    // returns a duplicate, must free
                if (label)      // if requested, label on 1st line only
                {
                    printf("%*s: ", width, (j == 0) ? label : "");
                }
                printf("%s (%.*s)%s", value, abbrev ? 1 : -1, kind, terminator);
                free((void *)kind);
            }
            break;
        case kABMultiDictionaryProperty:
            count = [field->value.multi count];

            if (field->property == kABAddressProperty)
            {
                for (unsigned int j = 0; j < count; j++)
                {
                    NSDictionary *value = [field->value.multi valueAtIndex:j];
                    const char *kind = str([field->value.multi labelAtIndex:j]);

                    kind = cleanLabel(kind);  // returns a duplicate
                    if (label)      // if requested, label on 1st line only
                    {
                        printf("%*s: ", width, (j == 0) ? label : "");
                    }
                    printf("%s, %s %s %s (%.*s)%s",
                            str([value objectForKey: kABAddressStreetKey]),
                            str([value objectForKey: kABAddressCityKey]),
                            str([value objectForKey: kABAddressStateKey]),
                            str([value objectForKey: kABAddressZIPKey]),
                            abbrev ? 1 : -1, kind, terminator);
                    free((void *)kind);
                }
            }
            else if (field->property == kABSocialProfileProperty)
            {
                for (unsigned int j = 0; j < count; j++)
                {
                    NSDictionary *value = [field->value.multi valueAtIndex:j];

                    if (label)       // multiple values
                    {
                        printf("%*s: ", width,
                               str([value objectForKey: kABSocialProfileServiceKey]));
                    }
                    printf("%s%s",
                            str([value objectForKey: kABSocialProfileUsernameKey]),
                            terminator);
                }
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
static void
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
static void
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
    for (unsigned int i=0; i<numElts(phoneLabels); i++)
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
    for (unsigned int i=0; i<numElts(emailLabels); i++)
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

static void
displayRaw(ABRecord *record)
{
    printf("%s\n", str([record description]));
}


/*
 * Display one group record
 */
static void
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
    unsigned long length = [members count];
    printf(" (%lu member%s)\n", length, plural(length));

    if (form == longDisplay)
    {
        NSEnumerator *membersEnum = [members objectEnumerator];
        ABPerson *person;
        while ((person = (ABPerson *)[membersEnum nextObject]))
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
static void
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
        if (form <= standardDisplay && i > email)   // stop here for standard
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

        if (form <= standardDisplay && i > email)   // stop here for standard
        {
            break;
        }

        if (form <= standardDisplay && i <= finalname)  // print formatted name
        {
            if (form != plainDisplay)
            {
                printf("%*s: ", labelWidth, "Name");
            }
            printFormattedName("\n");
            i = finalname;                          // skip other name fields
        }
        else
        {
            printField(&field[i], form == plainDisplay ? NULL : field[i].label,
                       labelWidth, "\n", false);
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

static NSArray *
search(ABAddressBook *book, int numTerms, char * const term[])
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
        for (int j=0; j<fieldLimit; j++)
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
static NSArray *
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
static const char *options = ":spblrnaghuCEGMUHW";
static struct option longopts[] =
{
     { "std",     no_argument,       NULL,           's' },
     { "brief",   no_argument,       NULL,           'b' },
     { "plain",   no_argument,       NULL,           'p' },
     { "long",    no_argument,       NULL,           'l' },
     { "raw",     no_argument,       NULL,           'r' },

     { "name",    no_argument,       NULL,           'n' },
     { "all",     no_argument,       NULL,           'a' },
     // FIXME { "group",   no_argument,       NULL,           'g' },

     { "help",    no_argument,       NULL,           'h' },
     { "uid",     optional_argument, NULL,           'u' },

     { "groups",  no_argument,       &listGroups,     1 },

     { "contacts", no_argument,       NULL,           'C' },
     { "email",    no_argument,       NULL,           'E' },
     { "google",   no_argument,       NULL,           'G' },
     { "maps",     no_argument,       NULL,           'M' },
     { "url",      no_argument,       NULL,           'U' },

     { "home",     no_argument,       NULL,           'H' },
     { "work",     no_argument,       NULL,           'W' },

     { NULL,      0,                 NULL,           0 }
};

static void __attribute__ ((noreturn))
usage(char *name)
{
    static char *help[] = {
      "  -s, --std      display records in standard form (default)",
      "  -p, --plain    display records in plain (no labels) form",
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
      "  -C, --contacts open Contacts with person",
      "  -E, --email    open email application with message for person",
      "  -G, --google   open google maps in browser to address of person",
      "  -M, --maps     open Maps with address of person",
      "  -U, --url      open browser with URL of person",
      "  -H, --home     use 'home' values for gui",
      "  -W, --work     use 'work' values for gui",
    };

    fprintf(stderr, "usage: %s [options] search term(s)\n", name);
    for (unsigned i=0; i<numElts(help); i++)
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
                case 'p': displayForm = plainDisplay;    break;
                case 'b': displayForm = briefDisplay;    break;
                case 'l': displayForm = longDisplay;     break;
                case 'r': displayForm = rawDisplay;      break;

                case 'n': searchFields = searchNames; break;
                case 'g': searchFields = searchGroups; break;
                case 'a': searchFields = searchAll;   break;

                case 'C': contactsGui = true; edit = false; break;
                case 'E': emailGui = true;            break;
                case 'M': mapsGui = true;             break;
                case 'G': googleMapsGui = true;       break;
                case 'U': urlGui = true;              break;

                case 'H': label = labelHome; break;
                case 'W': label = labelWork; break;

                case 'u': uid = true; uidStr = optarg; break;

                case 'h':
                default:
                    usage(programName);
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
            while ((group = (ABGroup *)[groupEnum nextObject]))
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
        while ((person = (ABPerson *)[addressEnum nextObject]))
        {
            display(person, displayForm);
            if (contactsGui)
            {
                openInContacts(person, edit);
                break;
            }
            if (urlGui)
            {
                openInBrowser(person, label);
                break;
            }
            if (googleMapsGui)
            {
                openInGoogleMapping(person, label);
                break;
            }
            if (mapsGui)
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
