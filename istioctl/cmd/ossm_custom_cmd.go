package cmd

import (
	"errors"
	"fmt"
	"strings"

	"github.com/spf13/cobra"
)

// The following fields are populated at build time using -ldflags -X.
var (
	// List of the disabled commands separated by a semicolon.
	// Eg: go build ... -ldflags -X PACKAGE_NAME/istioctl/cmd.disabledCmds=command1;command2;command3
	disabledCmds string

	// Optional: General message that is printed for every disabled commands.
	// Eg: go build ... -ldflags -X 'PACKAGE_NAME/istioctl/cmd.disabledCmdsMsg=command not supported in <this_context>'
	disabledCmdsMsg string

	// Optional: Additionnal information for specific commands.
	// Eg: go build ... -X 'PACKAGE_NAME/istioctl/cmd.disabledCmdsExtraInfo=command1=extra info about cmd1;command2=extra info about cmd2'
	disabledCmdsExtraInfo string
)

const (
	defaultDisabledCmdsMsg = "command is disabled"
)

type disabledCommand struct {
	name      string
	extraInfo string
}

// newDisableCommands creates the map of disabled commands from the 'disabledCmds' build ldflag.
func newDisableCommands(buildDisableCmds, buildExtraInfo string) map[string]*disabledCommand {
	commands := make(map[string]*disabledCommand)
	cmds := strings.Split(buildDisableCmds, ";")
	extra := strings.Split(buildExtraInfo, ";")

	// Adding disabled commands into the map
	for _, c := range cmds {
		commands[c] = &disabledCommand{
			name: c,
		}
	}

	// Setting the extra info for specific disabled commands
	for _, e := range extra {
		extraInfo := strings.SplitN(e, "=", 2)
		if len(extraInfo) == 2 {
			commands[extraInfo[0]].extraInfo = extraInfo[1]
		}
	}
	return commands
}

// disableCmd is used to set and return a command as disabled.
func disableCmd(cmd *cobra.Command, message, extraInfo string) *cobra.Command {
	cmdName := cmd.Name()

	msg := fmt.Sprintf("`%s` %s", cmdName, defaultDisabledCmdsMsg)

	if len(message) > 0 {
		msg = fmt.Sprintf("`%s` %s", cmdName, message)
	}

	if len(extraInfo) > 0 {
		msg = fmt.Sprintf("%s. Info: %s", msg, extraInfo)
	}

	return &cobra.Command{
		Use:   cmdName,
		Short: msg,
		RunE: func(_ *cobra.Command, _ []string) error {
			return errors.New(msg)
		},
	}
}

// disableCmds disables all the flagged "disabled" commands.
func disableCmds(root *cobra.Command) {
	disabledCommands := newDisableCommands(disabledCmds, disabledCmdsExtraInfo)
	for _, childCmd := range root.Commands() {
		if cmd, disabled := disabledCommands[childCmd.Name()]; disabled {
			root.RemoveCommand(childCmd)
			root.AddCommand(disableCmd(childCmd, disabledCmdsMsg, cmd.extraInfo))
		}
	}
}
