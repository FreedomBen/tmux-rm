# Not Run Yet

- On startup, if the config file doesn't already exist, write the default config file to the file location

# Already Run

- Let's note that we want the ability for users to change settings and add quick actions through the UI.  We'll also need an API so that the mobile app can do this as well.

- I'd like to add the ability to create  buttons that will execute common commands to make it easier, especially on mobile.  For example, if the user frequently runs a command like "git add . && git commit -m . && git push" they could add that so a button tap sends that text (as though they typed it).  Since we don't currently have a database, it would be great if all configuration (including this) we're human editable, like a yaml or json file.  What are your thoughts on this?
