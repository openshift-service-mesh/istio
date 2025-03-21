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

	// Optional: Specific message that gives the alternative ways of the disabled commands.
	// Eg: go build ... -X 'PACKAGE_NAME/istioctl/cmd.disabledCmdsAlternativeMsg=command1=alternative message cmd1;command2=alternative message cmd2'
	disabledCmdsAlternativeMsg string
)

const (
	defaultDisabledCmdsMsg = "command is disabled"
)

type disabledCommand struct {
	name        string
	disabled    bool
	alternative string
}

type disabledCommands struct {
	all []disabledCommand
}

func (dc *disabledCommands) setAlternativeByName(name, alternative string) {
	for i, c := range dc.all {
		if c.name == name {
			dc.all[i].alternative = alternative
			return
		}
	}
}

func (dc *disabledCommands) getAlternativeByName(name string) string {
	for i, c := range dc.all {
		if c.name == name {
			return dc.all[i].alternative
		}
	}
	return ""
}

func (dc *disabledCommands) isDisabledByName(name string) bool {
	for i, c := range dc.all {
		if c.name == name {
			return dc.all[i].disabled
		}
	}
	return false
}

// init adds the disabled commands from the 'disabledCmds' build ldflag.
func (dc *disabledCommands) init(buildExpr string) {
	cmds := strings.Split(buildExpr, ";")
	for _, c := range cmds {
		dc.all = append(dc.all, disabledCommand{
			name:        c,
			disabled:    true,
			alternative: "",
		})
	}
}

// setAlternativeMessages sets the disabled commands alternative messages
// from the 'disabledCmdsAlternativeMsg' build ldflag.
func (dc *disabledCommands) setAlternativeMessages(buildExpr string) error {
	cmds := strings.Split(buildExpr, ";")
	for _, c := range cmds {
		alt := strings.SplitN(c, "=", 2)
		if len(alt) != 2 {
			return errors.New("not correctly formatted")
		}
		dc.setAlternativeByName(alt[0], alt[1])
	}
	return nil
}

// disabledCmd is used to set a command as disabled.
func disabledCmd(cmd *cobra.Command, message, alternativeMsg string) *cobra.Command {
	cmdName := cmd.Name()

	msg := fmt.Sprintf("`%s` %s", cmdName, defaultDisabledCmdsMsg)

	if len(message) > 0 {
		msg = fmt.Sprintf("`%s` %s", cmdName, message)
	}

	if len(alternativeMsg) > 0 {
		msg = fmt.Sprintf("%s. Alternative: %s", msg, alternativeMsg)
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
func disableCmds(cmd *cobra.Command) {
	var dCmds disabledCommands
	dCmds.init(disabledCmds)
	dCmds.setAlternativeMessages(disabledCmdsAlternativeMsg)

	for _, c := range cmd.Commands() {
		if dCmds.isDisabledByName(c.Name()) {
			cmd.RemoveCommand(c)
			cmd.AddCommand(disabledCmd(c, disabledCmdsMsg, dCmds.getAlternativeByName(c.Name())))
		}
	}
}
