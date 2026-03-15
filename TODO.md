# Not Run Yet

- In the Android app, once we select a pane to attach to, we get an infinite loading circle that never completes.

- Let's update the README.md and CLAUDE.md files based on the recent work we've done, including implementing the android app.

Left on on Mar 14th.  Pickup the 15th or 16th:  We reviewed the android implementation plan.  Might do one more pass, then have it implmenet.  MCP finished, but not tested.

- Let's review the android implementation plan in ANDROID_IMPLEMENTATION.md before we move on to implementation.  Look for any errors, inconsistencies, ambiguities, or otherwise missing things that need to be corrected prior to implementation.

- Let's write an external test for the MCP server.

- In mobile 

- Let's add support for Cloudflare and Tailscale, so if an API key is present and the setting is enabled, we can update DNS and/or enable a tunnel.

- Let's add support for getting a TLS certificate from Let's Encrypt.  For this the user needs to enter the domain name or select to get an IP address certificate.

- Let's ensure we have full support for auth tokens, such that if the user wants to setup an auth token and disallow username/password auth, they can.  When auth token is enabled, the server should respond with a 401 or 403 to all requests that don't have the auth token included, even the home page. Does this request make sense?

# Already Run

- I really like the green color we used in the android app.  Let's update the web app UI to use that green color as well instead of the yellow/orange color we're currently using.

- Write a Makefile and include a build command, clean, and install, for the server and for the android app.  The server install should build and copy the server binary in place, and copy the systemd service file in place as well.  Do not run the install commands automatically.  I'll run them manually.  For the android app we should have an install-debug target that builds a debug apk and installed it to the attached android device over adb.

- We've finished initial implementation of the Android app as defined in ANDROID_IMPLEMENTATION.md .  Do a review check to see that we implemented it according to plan.

- Let's continue implementation for the Android app.  Read ANDROID_IMPLEMENTATION.md and continue with the next task.

- Let's begin implementation of the Android app.  Read ANDROID_IMPLEMENTATION.md and start with the first phase.

- Let's continue implementing the MCP server according to MCP_DESIGN.md.  (Implemented MCP resources: tmux://sessions, tmux://session/{name}/panes, tmux://pane/{target}/screen.  Added readOnlyHint annotations to read-only tools.  72 MCP tests passing.)

- Let's move on to implementing the android application.  Read through APPLICATION_DESIGN.md , and write an implementation plan to ANDROID_IMPLEMENTATION.md.

- We're ready to begin implementing the MCP server as described in MCP_DESIGN.md.

- Let's create an OpenAPI specification doc for this applications.  We should also serve it as a static asset.

- Let's do a final review on MCP_DESIGN.md to ensure it's still accurate with our latest code changes.  Look for any errors, inconsistencies, or ambiguities we need to iron out before moving to implementation.

- Let's add a close button (maybe a "x") to windows. This button should kill all the panes and window when clicked.  Show the user a confirmation prompt though since it might be easy to accidentally press.

- There seems to be a bug with the initial config file that get's written.  It doesn't have any quick_actions in it, just an empty array.  Let's make sure we're writing out the full config file on initial setup.

- Let's add a quick button for tab and for the up, left, right, and down arrows next to our control character buttons (like ^c, ^d, etc).

- In the mobile view, when user's click on a Window they're really just viewing a specific pane.  For consistency, should we label is "Pane" instead of "Window?

- Let's add settings to the settings page to change the app theme itself.  At a minimum we should have a light and dark theme.  Since this is a terminal program and many theme options are common, let's also brainstorm some other themes we could add.

- Do we need to clear the screen for the formatting issue?  It's very useful to not hide the history.  We do also need to figure out how to scroll up in the app.

- The enable/disable toggle in the settings page for quick actions doesn't appear to work.  It animates a bit but always comes back enabled.

- When first loading an existing pane, the formatting is very messed up.  It also gets mangled when tools like claude code edit text in place.  This is not an issue that real tmux experiences.  What are we doing differently that real tmux does when attaching to a session and opening a pane?  For an example, you can use the open browser to take a look yourself. attach to the "Termigate" session,window 1. If we need to resize the tmux pane to match our dimensions, I think that's acceptable.  That's how multiple tmux on different screens would do it after all.  

- Let's add a notification feature.  This is intended for long-running commands.  When a command finishes, pop up a notification informing the user.  Clicking on the notification should take you to the browser tab and put focus on the pane that triggered the notification.

- I don't see anywhere in the settings to configure the notification feature we added in @NOTIFICATIONS_DESIGN.md.  

- Let's continue implementation of the notifications feature as defined in @NOTIFICATIONS_DESIGN.md.  Continue with the first phase.  Update the document as you go to track what has been completed.

- Let's begin implementation of the notifications feature as defined in @NOTIFICATIONS_DESIGN.md.  Begin with the first phase.  Update the document as you go to track what has been completed.

- Let's add an Enabled/Disabled control on the settings page for quick actions, so the user can turn them on or off without wiping out their config.  This is useful if they don't need them currently and want to reclaim the screen real estate.

- Where do the terminal appearance settings get configured now?  I don't see them in the Settings page.  While we're at it, let's make sure and add every configurable value in the config file to the settings page.  We should also have a password change control in there as well.

- Let's make the space between panes narrower so it doesn't waste screen real estate.  A thin line would be better I think.  Also ensure the user can still resize by clicking and dragging on them.

- What's the purpose for the full view?

- Bug:  When I ran tmux split-window in a running pane, it seemed to work, but all the typed input went into the top pane (which was the original) instead of the bottom pane.  After I sent Ctrl+d to the top pane to close them, it began double registering key presses.

- Let's add an actions button row for sending control signals, especially Ctrl+C and Ctrl+D

- write up a README.md file for this repo

- I'm thinking about adding a notification feature.  This is intended for long-running commands.  When a command finishes, pop up a notification informing the user.  Clicking on the notification should take you to the browser tab and put focus on the pane that triggered the notification.  What are your thoughts on this?  would it be complex and difficult to do in a portable way?

- Let's make sure the reset to default button in settings doesn't override the saved password info.

- Where did the quick action buttons go?  Let's also add one for Ctrl+d, Ctrl+c, 

- Let's add a control for creating a new window in a session.

- Would adding support to this server for MCP provide any value?  Can you think of any situations where an AI agent may want to use it?

- When split in the UI, Let's make the panes resizable by click and dragging on the divider.  This should also work on mobile.

- When in initial setup, populate the username with the host OS user name

- Let's go through the application and ensure that we are logging any meaningful action.

- In the UI, clicking on a pane should cause the tmux focus to be shifted to that pane.

- What are our distribution options for the web app?  can we compile to a static binary for linux?

- How can we make our test suite run faster?  Right now it's pretty slow

- /init for each thing

- Let's write up a comprehensive implementation plan.  Break into phases if necessary.  Write each phase to a separate file in implementation-docs directory with names like PHASE_01_DO_SOMETHING.md.  Don't plan implementation for the android app quite yet, but do the entire server.  Make sure all features from APPLICATION_DESIGN.md are planned, and make sure we implement the tech stack from TECH_STACK.md.  

- Let's add the design details for the android app to APPLICATION_DESIGN.md .  Start with everything you already know and can infer from the rest of the document, and then make a list of things we need to decide on.

- Let's define out tech stack.  Write decision to TECH_STACK.md.  Write out what we already know, and let's discuss the remaining options.  We do want to use tailwind css.  I bought a tailwind UI/tailwind Plus license and have files in ~/gitclone/tailwind-ui-tailwind-plus/tailwindplus that you can and should use as a starting point.  What else do we need to decide on for the tech stack?

- On startup, if the config file doesn't already exist, write the default config file to the file location

- Let's note that we want the ability for users to change settings and add quick actions through the UI.  We'll also need an API so that the mobile app can do this as well.

- I'd like to add the ability to create  buttons that will execute common commands to make it easier, especially on mobile.  For example, if the user frequently runs a command like "git add . && git commit -m . && git push" they could add that so a button tap sends that text (as though they typed it).  Since we don't currently have a database, it would be great if all configuration (including this) we're human editable, like a yaml or json file.  What are your thoughts on this?
