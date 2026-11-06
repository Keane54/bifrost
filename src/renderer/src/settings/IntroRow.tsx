// The Introduction row of Settings > General. Its button shows the setup dialog again
// (spec 11.1). The open changes no setting.
import { DIALOG_BUTTON } from '../actions/ConfirmDialog'
import { GENERAL_ROWS } from './general-rows'
import { SettingRow } from './SettingRow'
import { useSettingsNav } from './settings-nav'

export default function IntroRow(): React.JSX.Element {
  const { showIntro } = useSettingsNav()
  return (
    <SettingRow label={GENERAL_ROWS.introduction}>
      <button
        className={DIALOG_BUTTON}
        data-settings-intro={true}
        onClick={showIntro}
        type='button'
      >
        Show introduction
      </button>
    </SettingRow>
  )
}
