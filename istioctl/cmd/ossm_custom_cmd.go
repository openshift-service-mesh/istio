// Copyright Istio Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package cmd

import (
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"
)

// The following fields are populated at build time using -ldflags -X.
var (
	// List of the disabled commands separated by a semicolon.
	// Eg: go build ... -ldflags -X PACKAGE_NAME/istioctl/cmd.notSupportedCmds=command1;command2;command3
	notSupportedCmds string

	// Optional: General message that is printed for every disabled commands.
	// Eg: go build ... -ldflags -X 'PACKAGE_NAME/istioctl/cmd.notSupportedCmdsMsg=command not supported in <this_context>'
	notSupportedCmdsMsg string
)

const (
	defaultNotSupportedCmdsMsg = "NOT SUPPORTED"
)

type notSupportedCommand struct {
	name      string
	extraInfo string
}

// newNotSupportedCommands creates the map of disabled commands from the 'notSupportedCmds' build ldflag.
func newNotSupportedCommands(buildNotSupportedCmds string) map[string]*notSupportedCommand {
	commands := make(map[string]*notSupportedCommand)
	cmds := strings.Split(buildNotSupportedCmds, ";")

	// Adding disabled commands into the map
	for _, c := range cmds {
		commands[c] = &notSupportedCommand{
			name: c,
		}
	}

	return commands
}

// setWarning sets a warning message for a not supported command.
func setWarning(cmd *cobra.Command, message string) {
	originalShort := cmd.Short
	msg := fmt.Sprintf("%s", defaultNotSupportedCmdsMsg)

	if len(message) > 0 {
		msg = fmt.Sprintf("%s", message)
	}

	cmd.Short = "[" + msg + "] " + originalShort
	originalRunE := cmd.RunE
	originalRun := cmd.Run

	cmd.RunE = func(c *cobra.Command, args []string) error {
		fmt.Fprintf(os.Stderr, "WARNING: %s\n", msg)

		if originalRunE != nil {
			return originalRunE(c, args)
		}
		if originalRun != nil {
			originalRun(c, args)
		}
		return nil
	}
}

// setWarningCmds recursively traverses the command tree and sets warnings.
func setWarningCmds(cmd *cobra.Command, notSupportedCommands map[string]*notSupportedCommand) {
	for _, childCmd := range cmd.Commands() {
		if _, notSupported := notSupportedCommands[childCmd.Name()]; notSupported {
			setWarning(childCmd, notSupportedCmdsMsg)
		}
		// Recursively check children of this command
		setWarningCmds(childCmd, notSupportedCommands)
	}
}

// setNotSupportedWarningCmds adds warnings to all the flagged "not supported" commands.
func setNotSupportedWarningCmds(root *cobra.Command) {
	notSupportedCommands := newNotSupportedCommands(notSupportedCmds)
	setWarningCmds(root, notSupportedCommands)
}
