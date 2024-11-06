# Updating the app after a pull request

In general, we use `main` as our primary branch and when we're ready
to do a release we merge changes from `main` into the `release` branch
and push this branch to GitHub. Xcode Cloud will listen for changes to
this branch and kick off the deployment process, automatically posting
the updated code to TestFlight.

After a pull request, to deploy a change:

```bash
$ git checkout main
$ git pull
$ git log # make sure that the changes are in main
$ git checkout release
$ git merge main
$ git log # make sure that release and main are consistent
$ git push
```