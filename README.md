# Azure DevOps Automation Tools 

All these tools are built in PowerShell and have both a $data and a $output folder.

The expectation is that you would create a new git repo just for the data and output folders and then use the scripts to generate the data and output content that you would then use as input into your migrations.

A Sample data folder is provided in this repo.

## Setting up the environment

1. Clone this repository 
2. Install Visual Studio Code (https://code.visualstudio.com/)  
3. Enable Powershell Plugins in Visual Studio Code 
4. Install Powershell 7

## Run the Scripts with your own data

The scripts use `config.json` in the root of this repo to determine where to find the data and where to put the output. It will be generated if it does not exist, and you can initiate it by running `runmefirst.ps1`. 

### SAMPLE CONFIG.JSON
```
{
  "dataFolder": "..\\my-data-repo\\data\\",
  "dataEnvironment": "debug",
  "queryString": "api-version=7.0",
  "outputFolder": "..\\my-data-repo\\output\\"
}

```
Although you can use the default values, this will store your data in untracked files in the same repo as the scripts. You would ecperiance data loss if this folder were to be deleted. We recommend that you create a new git repo for your data and output folders and then use the scripts to generate the data and output content that you would then use as input into your migrations.

Once you have your config.json set up, you can run the follwoing scripts:

- **Generate-ConfigurationsFromTemplates.ps1** - This will generate a configuration file for each template file in the data folder. Loaded from `migrationConfigSaples` folder and it will create a folder for each project on each organisation configured with the template populated for every project. This assumes that you are migrating many projects to a single organisation. If you are migrating a single project to many organisations, you will need to edit the output with the target locations.
- **Delete-CustomField.ps1** - Woops, I deen to delete a field from an organisation. This will delete a field from all projects in an organisation.
- **Generate-ProcessOutput.ps1** - This will populate the process, list, field, and work item configuration data from all of the processes in each org. It will create a folder for each organisation and populate it with the data. This is for reference and can be used to build the input for the other scripts.
- **Generate-ProjectStats.ps1**- How big is my migration? Createa a CSV file with the number of work items, pipelines, builds, and other data in each project in each organisation.
- **Install-CustomFields.ps1** - Adds all of the configured fields to the configured organisations and processes. Fields are enabled in `DataLocation\fields.json` and each field is configured in `DataLocation\fields\{field-name}.json`. This script will create the fields in the configured organisations and processes.
- **Install-CustomPages.ps1** - Adds all of the configured pages to the configured organisations and processes. Each page is configured in `DataLocation\pages\{page-name}.json`. This script will create the pages in the configured organisations,  processes, & WorkItems.
- **Install-ReflectedWorkItemID.ps1** - Adds the ReflectedWorkItemID field to all of the configured organisations and processes. This is a special field that is used by the [Azure DevOps Migration Tools(https://github.com/nkdAgility/azure-devops-migration-tools)] to track the work items as they are migrated. This script will create the field in the configured organisations and processes.
- **Search-ProcessesWeCareAbout.ps1** - This will search all of the configured organisations for processes that contain the configured work item field. This is useful if you are looking for a process that you know contains a specific field. It will create a CSV file with the results, and update the `organisations.json` file.

## Data Folder

The data folder contains the data that is used to for each Script. You can check the `.\data\sample\*` folder for examples of the data required.

- `organisations.json` - This is a list of all of the organsaitions and PAT tokens used for access. They can be disabled, and the scripts will skip them. This is used by all of the scripts.
- `ReflectedWorkItemId.json` - This contains the single field configuration for the ReflectedWorkItemId field. This is used by the `Install-ReflectedWorkItemID.ps1` script.
- `fields.json` - This contains the list of fields to be created. This is used by the `Install-CustomFields.ps1` script, and each field can be enabled or disabled. It will load the indevidual field from the `fields` folder based on the `refname` peoperty.
- `fields\{field-name}.json` - This contains the configuration for each field. This is used by the `Install-CustomFields.ps1` script. Each field definition contains all of the POST information needed to create and add them to a process.
- `pages\{page-name}.json` - This contains the configuration for each page. This is used by the `Install-CustomPages.ps1` script. Each page definition contains all of the POST information needed to create and add them to a process. `Pages` are iterated over and you can use them to add `Groups` to existing `Pages`.
- `templates\{template-name}.json` - This contains templates for diferent [Azure DevOps Migration Tools(https://github.com/nkdAgility/azure-devops-migration-tools)] configurations. This is used by the `Generate-ConfigurationsFromTemplates.ps1` script. Each configuration template will have the source updated to reflect the source organisation and project, the target will not be updated.

## Documentation for POSTS

- [Create Field](https://learn.microsoft.com/en-us/rest/api/azure/devops/wit/fields/create?view=azure-devops-rest-7.0&tabs=HTTP)
- [Create Picklist](https://learn.microsoft.com/en-us/rest/api/azure/devops/processes/lists/create?view=azure-devops-rest-7.0&tabs=HTTP)
- [Add Field](https://learn.microsoft.com/en-us/rest/api/azure/devops/processes/fields/add?view=azure-devops-rest-7.0&tabs=HTTP)
- [Add Control](https://learn.microsoft.com/en-us/rest/api/azure/devops/processes/controls/create?view=azure-devops-rest-7.0&tabs=HTTP)