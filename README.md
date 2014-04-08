# abc

Command-line access to OSX Contacts (nee Address Book).

"Abc" used to mean "Address Book Client", but then Apple decided to rename their app.   So now it is "A Better Contacts".

### Why?
Because it's faster.  If you've got a terminal window open, just type 'abc name'.  No clicks required.

### Usage:
    # abc -h

    usage: abc [options] search term(s)
        -s, --std      display records in standard form (default)
        -b, --brief    display records in brief form
        -l, --long     display records in long form
        -r, --raw      display records in raw form

        -a, --all      search all Person fields (default)
        -n, --name     search name fields only

        -h, --help     this help
        -u, --uid[=id] display unique ids; search for id if given

        --groups   list all groups

        -C, --contacts open Contacts with person
        -E, --email    open email application with message for person
        -G, --google   open google maps in browser to address of person
        -M, --maps     open Maps with address of person
        -U, --url      open browser with URL of person
        -H, --home     use 'home' values for gui
        -W, --work     use 'work' values for gui

### Examples:
* Look up John Smith's info:
```
abc john smith
```

* Compose email to him with Mail.app:
```
abc john smith -E
```

* Open his personal webpage:
```
abc john smith -U -H
```

* Open his work webpage:
```
abc john smith -U -W
```

* Map his first address in Maps.app:
```
abc john smith -M
```

* Map his first address via maps.google.com:
```
abc john smith -G
```

### Building:
No, there's no project file.  Real men don't need GUIs.

    clang -framework Foundation -framework AddressBook -framework AppKit \
        -Wall -Werror -Weverything -Wno-format-nonliteral \
        -Wno-missing-field-initializers -Wno-shadow \
        -o abc abc.m

### Installing:
No, there's no package installer.  See above.

    sudo cp abc /usr/local/bin
