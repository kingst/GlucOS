If you have just cloned the repository and need to initialize and
update the submodules, you can use:

```bash
git submodule update --init --recursive
```

This initializes all submodules and updates them to their respective
commits as specified in the superproject's configuration.

To update the submodules to the latest changes in their respective
repositories, you can use:

```bash
git submodule update --remote
```

This command fetches the latest changes from the upstream repositories
of the submodules and updates them in your superproject.

If you want to update a specific submodule, you can navigate to the
submodule directory and use standard Git commands. For example:

```bash
cd path/to/submodule
git pull
```

This updates the specific submodule as if it were its own Git
repository.

After running these commands, your submodules will be updated to the
latest commits, and you can commit these changes in the superproject
to record the updated submodule states.

To add a new submodule first get the sha that you want to use:

```bash
cd LoopWorkspace/MODULE
git rev-parse HEAD
# this gives you the SHA to use
```

Then back in the main repo:

```bash
git submodule add https://submodule.git ios/submodule
cd ios/submodule
git checkout SHA
cd ../..
git commit
```