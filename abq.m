/*
 * Simple AddressBook query CLI
 * Copyright 2012 Mike Carlton
 *
 * Released under terms of the MIT License: 
 * http://www.opensource.org/licenses/mit-license.php
 *
 * build: 
 * clang -framework Foundation -framework AddressBook -framework AppKit -Wall -o abq abq.m
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
} Label;

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
    searchAll,
} SearchFields;

Boolean emailGui = false;   // open gui email?
Boolean mapGui = false;     // open gui map?
Boolean abGui = false;      // open gui address book?
Boolean edit = false;       // gui address book in edit mode?

Boolean uid = false;        // display records with uid?

Label label = labelNone;                    // use which label?
DisplayForm displayForm = standardDisplay;  // type of display
SearchFields searchFields = searchNames;    // type of search

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
    address,
    phone,
    email,
    organization,
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
        { "Address",      kABAddressProperty,      kABMultiDictionaryProperty },
        { "Phone",        kABPhoneProperty,        kABMultiStringProperty },
        { "Email",        kABEmailProperty,        kABMultiStringProperty },
        { "Organization", kABOrganizationProperty, kABStringProperty },
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

/* 
 * Open up the email application with the person displayed
 */
void openInEmail(ABPerson *person)
{
    ABMultiValue *email = [person valueForProperty:kABEmailProperty];

    NSString *identifier = [email primaryIdentifier]; 
    if (!identifier)        // if they don't have a primary identified
    {
        identifier = [email identifierAtIndex:0];   // just use first
    }

    if (identifier)
    {
        NSString *address = [email valueForIdentifier:identifier];
        NSString *url = [NSString stringWithFormat:@"mailto:%@", address];

        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
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

const char 
*str(NSString *ns)
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
 * Labels come out of AB like this: _$!<Work>!$_ 
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
 * Allocate and return a formatted name
 */
void
printFormattedName(char *terminator)
{
    int first = firstname;

    if (field[nickname].value.generic)
    {
        first = nickname;
    }
    printField(&field[first], NULL, 0, " ", true);
    printField(&field[lastname], NULL, 0, terminator, true);
}

void
displayBrief(ABPerson *person)
{
    printFormattedName(" ");
    printField(&field[phone], NULL, 0, " ", true);
    printField(&field[email], NULL, 0, " ", true);
    printf("\n");
}

void 
displayRaw(ABPerson *person)
{
    printf("%s\n", str([person description]));
}

/*
 * Display one record
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
        field[i].value.generic = [person valueForProperty:field[i].property];
        if (field[i].value.generic && field[i].labelWidth > labelWidth)
        {
            labelWidth = field[i].labelWidth;
        }
    }

    /* if brief requested, print it and return */
    if (form == briefDisplay)
    {
        displayBrief(person);
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

    /* search all records for each term */
    ABSearchElement *search = [ABSearchElement 
                                searchElementForConjunction:kABSearchAnd
                                children:searchTerms];

    return [book recordsMatchingSearchElement:search];
}

/*
    search filters:
        first F 
        first L 
        notes N
        email M
        city C
        street S
    display type:
        short
        normal
        long
    limit n <arg>
    interactive i
 */

/*
 * Summarize program usage 
 */
static const char *options = ":sblrnahAEMHWu";

static void 
usage(char *name)
{
    int i;
    static char *help[] = {
      "  -s        display records in standard form (default)",
      "  -b        display records in brief form",
      "  -l        display records in long form",
      "  -r        display records in raw form",
      "",
      "  -n        search name fields only (default)",
      "  -a        search all fields",
      "",
      "  -h        this help",
      "  -A        open Address Book with person",
      "  -E        open email application with message for person",
      "  -M        open map application wiht address of person",
      "  -H        use 'home' values for gui",
      "  -W        use 'work' values for gui",
      "  -u [id]   display unique ids; search for id if given",
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
        while ((opt = getopt(argc, argv, options)) > 0) 
        {
            switch (opt) 
            {
                case 's': displayForm = standardDisplay; break;
                case 'b': displayForm = briefDisplay;    break;
                case 'l': displayForm = longDisplay;     break;
                case 'r': displayForm = rawDisplay;      break;

                case 'n': searchFields = searchNames; break;
                case 'a': searchFields = searchAll;   break;

                case 'A': abGui = true; edit = false; break;
                case 'E': emailGui = true;            break;
                case 'M': mapGui = true;              break;

                case 'H': label = labelHome; break;
                case 'W': label = labelWork; break;

                case 'u': uid = true; break;

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
            display(person, displayForm);
            if (abGui)
            {
                openInAddressBook(person, edit);
                break;
            }
            if (emailGui)
            {
                openInEmail(person);
                break;
            }
        }

        unsigned long numResults = [results count];
        printf("%lu match%s\n", numResults, eplural(numResults));
    }

    return 0;
}

/* vim: set ts=4 sw=4 sts=4 et: */
