# Not Run Yet

- Let's add the design details for the android app to APPLICATION_DESIGN.md .  Start with everything you already know and can infer from the rest of the document, and then make a list of things we need to decide on.

- let's write up a comprehensive implementation plan.  break into phases if necessary.  Write each phase to a seprate file in implementation-docs directory with names like
  PHASE_01_DO_SOMETHING.md.  Don't plan implementation for the android app quite yet.

- Let's go through the application and ensure that we are logging any meaningful action.

# Already Run

- Let's define out tech stack.  Write decision to TECH_STACK.md.  Write out what we already know, and let's discuss the remaining options.  We do want to use tailwind css.  I bought a tailwind UI/tailwind Plus license and have files in ~/gitclone/tailwind-ui-tailwind-plus/tailwindplus that you can and should use as a starting point.  What else do we need to decide on for the tech stack?

- On startup, if the config file doesn't already exist, write the default config file to the file location

- Let's note that we want the ability for users to change settings and add quick actions through the UI.  We'll also need an API so that the mobile app can do this as well.

- I'd like to add the ability to create  buttons that will execute common commands to make it easier, especially on mobile.  For example, if the user frequently runs a command like "git add . && git commit -m . && git push" they could add that so a button tap sends that text (as though they typed it).  Since we don't currently have a database, it would be great if all configuration (including this) we're human editable, like a yaml or json file.  What are your thoughts on this?
