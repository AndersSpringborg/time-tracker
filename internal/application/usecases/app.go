package usecases

type App struct {
	Rules     *RulesUsecase
	Reports   *ReportsUsecase
	Projects  *ProjectsUsecase
	Settings  *SettingsUsecase
	Lifecycle *LifecycleUsecase
	Review    *ReviewUsecase
	Help      *HelpUsecase
}
