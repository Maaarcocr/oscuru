import { setDetail, DETAIL_SPECS, type DetailSettings } from '@/engine/state';
import { t, type StringKey } from '@/i18n';
import { SectionTitle, SliderRow } from '../controls';
import { GlobalSlider, PanelScroll, type PanelProps } from './shared';

const signed = (value: number): string => (value > 0 ? `+${value.toFixed(2)}` : value.toFixed(2));

export function LightPanel(props: PanelProps) {
  return (
    <PanelScroll>
      <GlobalSlider {...props} name="exposureEV" format={signed} />
      <GlobalSlider {...props} name="contrast" />
      <GlobalSlider {...props} name="highlights" />
      <GlobalSlider {...props} name="shadows" />
      <GlobalSlider {...props} name="whites" />
      <GlobalSlider {...props} name="blacks" />
    </PanelScroll>
  );
}

export function ColorPanel(props: PanelProps) {
  return (
    <PanelScroll>
      <SectionTitle>{t('section.whiteBalance')}</SectionTitle>
      <GlobalSlider {...props} name="temperature" format={(value) => `${Math.round(value)} K`} />
      <GlobalSlider {...props} name="tint" />
      <SectionTitle>{t('section.presence')}</SectionTitle>
      <GlobalSlider {...props} name="vibrance" />
      <GlobalSlider {...props} name="saturation" />
    </PanelScroll>
  );
}

function DetailSlider(props: PanelProps & { name: keyof DetailSettings }) {
  const { session, snapshot, name } = props;
  const spec = DETAIL_SPECS[name];
  const label = t(`param.${name}` as StringKey);
  return (
    <SliderRow
      testID={`slider-${name}`}
      label={label}
      value={snapshot.state.detail[name]}
      min={spec.min}
      max={spec.max}
      step={spec.step}
      resetTo={Math.round(session.info.defaults[name])}
      onChange={(value) => session.update((state) => (state.detail[name] === value ? state : setDetail(state, { [name]: value })))}
      onCommit={() => session.commit(label)}
    />
  );
}

export function DetailPanel(props: PanelProps) {
  return (
    <PanelScroll>
      <SectionTitle>{t('section.detail')}</SectionTitle>
      <DetailSlider {...props} name="sharpening" />
      <DetailSlider {...props} name="noiseReduction" />
      {props.session.info.isRaw ? <DetailSlider {...props} name="colorNoiseReduction" /> : null}
      <SectionTitle>{t('section.effects')}</SectionTitle>
      <GlobalSlider {...props} name="texture" />
      <GlobalSlider {...props} name="clarity" />
      <GlobalSlider {...props} name="dehaze" />
      <GlobalSlider {...props} name="vignette" />
    </PanelScroll>
  );
}
