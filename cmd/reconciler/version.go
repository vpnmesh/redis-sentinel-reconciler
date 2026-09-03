package main

import "fmt"

// Set at link time by scripts/package-linux-amd64.sh (GitHub Release).
var (
	version = "dev"
	commit  = ""
)

func printVersion() {
	if commit != "" && commit != "none" {
		fmt.Printf("redis-sentinel-reconciler %s (%s)\n", version, commit)
		return
	}
	fmt.Printf("redis-sentinel-reconciler %s\n", version)
}

func wantsVersion(args []string) bool {
	for _, a := range args {
		if a == "-version" || a == "--version" {
			return true
		}
	}
	return false
}
